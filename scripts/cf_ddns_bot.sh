#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
WORKER="$BASE_DIR/cf_ddns.sh"
CHANGER="$BASE_DIR/cf_change_ip.sh"
LOG_FILE="/var/log/cf_ddns.log"
BOT_LOCK_FILE="/run/cf-ddns-bot-command.lock"
HEADER_CACHE_FILE="/run/cf-ddns-bot-header.cache"
HEADER_CACHE_TTL=10
PANEL_IMAGE_FILE="${PANEL_IMAGE_FILE:-}"
MIN_PANEL_IMAGE_BYTES=1000
CF_API_BASE="https://api.cloudflare.com/client/v4"
TIMER_UNIT_FILE="/etc/systemd/system/cf-ddns.timer"

# 公网 IP 数据源（多源容错）。
PUBLIC_IP4_SOURCES=(
  "https://api.ipify.org"
  "https://ipv4.icanhazip.com"
  "https://ifconfig.me/ip"
)
PUBLIC_IP6_SOURCES=(
  "https://api6.ipify.org"
  "https://ipv6.icanhazip.com"
  "https://ifconfig.co/ip"
)

log() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%F %T')" "$message" | tee -a "$LOG_FILE"
}

log_only() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%F %T')" "$message" >> "$LOG_FILE"
}

die() {
  log "错误：$1"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }

split_records() {
  local raw="$1"
  raw="${raw//,/ }"
  printf '%s\n' $raw
}

get_public_ip() {
  local record_type="${1:-A}"
  local sources=() proto ip src

  if [[ "$record_type" == "AAAA" ]]; then
    sources=("${PUBLIC_IP6_SOURCES[@]}")
    proto="-6"
  else
    sources=("${PUBLIC_IP4_SOURCES[@]}")
    proto="-4"
  fi

  for src in "${sources[@]}"; do
    ip="$(curl -fsS "$proto" --retry 1 --connect-timeout 5 --max-time 10 "$src" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "$record_type" == "AAAA" ]]; then
      is_ipv6 "$ip" && { printf '%s\n' "$ip"; return 0; }
    else
      is_ipv4 "$ip" && { printf '%s\n' "$ip"; return 0; }
    fi
  done

  printf '未知\n'
  return 1
}

is_valid_panel_image() {
  local image_file="$1"
  local byte_count magic trailer

  [[ -f "$image_file" ]] || return 1
  byte_count="$(wc -c < "$image_file" 2>/dev/null | tr -d ' ')"
  [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1

  case "$image_file" in
    *.jpg|*.jpeg)
      [[ "$byte_count" -ge "$MIN_PANEL_IMAGE_BYTES" ]] || return 1
      magic="$(LC_ALL=C od -An -N2 -tx1 "$image_file" 2>/dev/null | tr -d ' \n')"
      [[ "$magic" == "ffd8" ]]
      ;;
    *.png)
      [[ "$byte_count" -ge "$MIN_PANEL_IMAGE_BYTES" ]] || return 1
      magic="$(LC_ALL=C od -An -N8 -tx1 "$image_file" 2>/dev/null | tr -d ' \n')"
      [[ "$magic" == "89504e470d0a1a0a" ]] || return 1
      # 拒绝被截断的 PNG：必须以完整的 IEND 块结尾，否则 Telegram 会报 IMAGE_PROCESS_FAILED。
      trailer="$(LC_ALL=C tail -c 12 "$image_file" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
      [[ "$trailer" == "0000000049454e44ae426082" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

load_config() {
  [[ -f "$ENV_FILE" ]] || die "找不到配置文件：$ENV_FILE，请先执行 ddns 初始化配置。"
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  [[ "${TG_ENABLED:-false}" == "true" ]] || die "Telegram 未启用。"
  [[ -n "${TG_BOT_TOKEN:-}" ]] || die "TG_BOT_TOKEN 不能为空。"
  [[ -n "${TG_CHAT_ID:-}" ]] || die "TG_CHAT_ID 不能为空。"
}

tg_api() {
  local method="$1"
  shift
  # --retry-connrefused：让 --retry 也覆盖连接被拒/连接超时这类瞬时网络错误。
  curl -fsS --retry 2 --retry-delay 2 --retry-connrefused \
    --connect-timeout 10 --max-time 60 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/${method}" "$@"
}

send_message() {
  local chat_id="$1"
  local text="$2"
  tg_api sendMessage \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    >/dev/null || log "Telegram 消息发送失败。"
}

send_html_message() {
  local chat_id="$1"
  local html="$2"
  tg_api sendMessage \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${html}" \
    --data-urlencode "parse_mode=HTML" \
    >/dev/null || log "Telegram HTML 消息发送失败。"
}

send_json() {
  local method="$1"
  local payload="$2"

  tg_api "$method" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    >/dev/null || log "Telegram ${method} 请求失败。"
}

# ===== Cloudflare 只读查询（用于面板展示同步状态）=====
cf_api() {
  local method="$1"
  local endpoint="$2"
  curl -fsS --retry 1 --connect-timeout 6 --max-time 15 \
    -X "$method" "$CF_API_BASE$endpoint" \
    -H "Authorization: Bearer ${CF_API_TOKEN:-}" \
    -H "Content-Type: application/json"
}

cf_zone_id() {
  [[ -n "${CF_API_TOKEN:-}" && -n "${ZONE_NAME:-}" ]] || return 1
  local q resp
  q="$(jq -rn --arg v "$ZONE_NAME" '$v|@uri')"
  resp="$(cf_api GET "/zones?name=${q}&status=active" 2>/dev/null)" || return 1
  jq -er '.result[0].id // empty' <<<"$resp" 2>/dev/null
}

cf_get_record_ip() {
  local zone_id="$1" name="$2" type="$3" q resp
  q="$(jq -rn --arg v "$name" '$v|@uri')"
  resp="$(cf_api GET "/zones/${zone_id}/dns_records?type=${type}&name=${q}" 2>/dev/null)" || return 1
  jq -er '.result[0].content // empty' <<<"$resp" 2>/dev/null
}

timer_interval() {
  [[ -f "$TIMER_UNIT_FILE" ]] || { printf '未知'; return; }
  local v cal
  # 兼容旧版 OnUnitActiveSec=Nmin。去掉首尾空白，避免读到空字符串显示「未知」。
  v="$(sed -n 's/^[[:space:]]*OnUnitActiveSec[[:space:]]*=[[:space:]]*//p' "$TIMER_UNIT_FILE" 2>/dev/null | head -n1)"
  v="${v//[[:space:]]/}"
  if [[ -z "$v" ]]; then
    # 新版定时器用 OnCalendar（如 *:0/2 表示每 2 分钟）。容错提取分钟步进 /N。
    cal="$(sed -n 's/^[[:space:]]*OnCalendar[[:space:]]*=[[:space:]]*//p' "$TIMER_UNIT_FILE" 2>/dev/null | head -n1)"
    cal="${cal%%[[:space:]]*}"
    if [[ "$cal" =~ /([0-9]+)$ ]]; then
      v="${BASH_REMATCH[1]}min"
    elif [[ -n "$cal" ]]; then
      v="$cal"
    fi
  fi
  printf '%s' "${v:-未知}"
}

resolve_panel_image_file() {
  if [[ -n "${PANEL_IMAGE_FILE:-}" ]] && is_valid_panel_image "$PANEL_IMAGE_FILE"; then
    printf '%s\n' "$PANEL_IMAGE_FILE"
    return 0
  fi

  if is_valid_panel_image "$BASE_DIR/panel_illustration.png"; then
    printf '%s\n' "$BASE_DIR/panel_illustration.png"
  elif is_valid_panel_image "$BASE_DIR/panel_illustration.jpg"; then
    printf '%s\n' "$BASE_DIR/panel_illustration.jpg"
  fi
}

send_photo_response() {
  local chat_id="$1"
  local caption="$2"
  local reply_markup="$3"
  local image_file="$4"
  local tmp_body http_status curl_status response image_mime image_name

  image_mime="image/png"
  image_name="panel_illustration.png"
  case "$image_file" in
    *.jpg|*.jpeg)
      image_mime="image/jpeg"
      image_name="panel_illustration.jpg"
      ;;
  esac

  tmp_body="$(mktemp)"
  curl_status=0
  http_status="$(curl -sS --retry 2 --connect-timeout 10 --max-time 60 \
    -w '%{http_code}' \
    -o "$tmp_body" \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendPhoto" \
    --form-string "chat_id=${chat_id}" \
    -F "photo=@${image_file};filename=${image_name};type=${image_mime}" \
    --form-string "caption=${caption}" \
    --form-string "parse_mode=HTML" \
    --form-string "reply_markup=${reply_markup}" 2>&1)" || curl_status=$?

  response="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body"

  if [[ "$curl_status" -ne 0 ]]; then
    log_only "Telegram 图片面板 curl 失败：$http_status；响应：$response"
    return 1
  fi

  if [[ "$http_status" != 2* ]]; then
    log_only "Telegram 图片面板 HTTP ${http_status}：$response"
    return 1
  fi

  if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"$response"; then
    log_only "Telegram 图片面板响应异常：$response"
    return 1
  fi

  printf '%s\n' "$response"
}

send_panel_text_response() {
  local chat_id="$1"
  local caption="$2"
  local payload

  payload="$(jq -n \
    --arg chat_id "$chat_id" \
    --arg text "$caption" \
    --argjson reply_markup "$(panel_markup)" \
    '{chat_id:$chat_id,text:$text,parse_mode:"HTML",reply_markup:$reply_markup}')"
  tg_api sendMessage \
    -H "Content-Type: application/json" \
    --data "$payload"
}

send_panel_text() {
  local chat_id="$1"
  local caption="$2"

  send_panel_text_response "$chat_id" "$caption" >/dev/null || log "Telegram 面板消息发送失败。"
}

answer_callback_query() {
  local callback_id="$1"
  local text="${2:-}"

  local payload
  payload="$(jq -n \
    --arg callback_query_id "$callback_id" \
    --arg text "$text" \
    '{callback_query_id:$callback_query_id,text:$text,show_alert:false}')"
  send_json answerCallbackQuery "$payload"
}

configure_bot_commands() {
  local payload

  payload="$(jq -n '{
    commands: [
      {command:"start", description:"打开控制面板"},
      {command:"panel", description:"打开控制面板"},
      {command:"changeip", description:"换 IP 并更新 DDNS"},
      {command:"ddns", description:"立即运行 DDNS"},
      {command:"status", description:"刷新状态"},
      {command:"log", description:"查看最近日志"},
      {command:"help", description:"帮助"}
    ]
  }')"

  send_json setMyCommands "$payload"
}

panel_markup() {
  local timer_state toggle_text toggle_data
  timer_state="$(systemctl is-active cf-ddns.timer 2>/dev/null || true)"
  if [[ "$timer_state" == "active" ]]; then
    toggle_text="⏸️ 停用定时器"
    toggle_data="timer_off"
  else
    toggle_text="▶️ 启用定时器"
    toggle_data="timer_on"
  fi

  jq -cn \
    --arg toggle_text "$toggle_text" \
    --arg toggle_data "$toggle_data" \
    '{
      inline_keyboard: [
        [
          {text:"🔁 换 IP", callback_data:"changeip"},
          {text:"📡 更新 DDNS", callback_data:"ddns"}
        ],
        [
          {text:"🔄 刷新", callback_data:"refresh"},
          {text:"📜 日志", callback_data:"log"}
        ],
        [
          {text:$toggle_text, callback_data:$toggle_data},
          {text:"ℹ️ 帮助", callback_data:"help"}
        ]
      ]
    }'
}

# 渲染各记录的同步状态块（公网 IP ↔ Cloudflare 记录值）。
render_records_block() {
  local zone_id="$1" record_type="$2" public_ip="$3"
  local -a recs=()
  local _r
  while IFS= read -r _r; do
    [[ -n "$_r" ]] && recs+=("$_r")
  done < <(split_records "${RECORD_NAME:-}")

  [[ "${#recs[@]}" -gt 0 ]] || return 0

  local out="" name content mark shown=0 total="${#recs[@]}"
  for name in "${recs[@]}"; do
    [[ -n "$name" ]] || continue
    shown=$((shown + 1))
    if [[ "$shown" -gt 5 ]]; then
      out+="… 其余 $((total - 5)) 条已省略"$'\n'
      break
    fi
    content=""
    [[ -n "$zone_id" ]] && content="$(cf_get_record_ip "$zone_id" "$name" "$record_type" 2>/dev/null || true)"
    if [[ -z "$content" ]]; then
      mark="❔"; content="未知"
    elif [[ "$content" == "$public_ip" ]]; then
      mark="✅"
    else
      mark="⚠️"
    fi
    out+="$(printf '🧭 %s → <code>%s</code> %s' "$(html_escape "$name")" "$(html_escape "$content")" "$mark")"$'\n'
  done
  printf '%s' "${out%$'\n'}"
}

# 查询公网 IP 的地区 / ISP 归属（尽力而为，失败则静默）。
# 默认启用，可在配置中关闭（GEO_ENABLED=false）。
# 注意：会把本机公网 IP 发给第三方地理库查询。
geo_lookup() {
  local ip="$1" resp country region city isp place out
  [[ "${GEO_ENABLED:-true}" == "true" ]] || return 1
  [[ -n "$ip" && "$ip" != "未知" ]] || return 1

  # 1) ip-api.com：支持中文本地化（免费版仅 HTTP）
  resp="$(curl -fsS --connect-timeout 5 --max-time 8 \
    "http://ip-api.com/json/${ip}?lang=zh-CN&fields=status,country,regionName,city,isp" 2>/dev/null || true)"
  if [[ -n "$resp" ]] && jq -e '.status=="success"' >/dev/null 2>&1 <<<"$resp"; then
    country="$(jq -r '.country // ""' <<<"$resp")"
    region="$(jq -r '.regionName // ""' <<<"$resp")"
    city="$(jq -r '.city // ""' <<<"$resp")"
    isp="$(jq -r '.isp // ""' <<<"$resp")"
  else
    # 2) ipwho.is：HTTPS 备用（英文）
    resp="$(curl -fsS --connect-timeout 5 --max-time 8 "https://ipwho.is/${ip}" 2>/dev/null || true)"
    if [[ -n "$resp" ]] && jq -e '.success==true' >/dev/null 2>&1 <<<"$resp"; then
      country="$(jq -r '.country // ""' <<<"$resp")"
      region="$(jq -r '.region // ""' <<<"$resp")"
      city="$(jq -r '.city // ""' <<<"$resp")"
      isp="$(jq -r '.connection.isp // ""' <<<"$resp")"
    else
      return 1
    fi
  fi

  place="$city"
  [[ -z "$place" ]] && place="$region"
  out="$country"
  [[ -n "$place" && "$place" != "$country" ]] && out="${out:+$out }$place"
  [[ -n "$isp" ]] && out="${out:+$out · }$isp"

  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

build_panel_header() {
  local record_type public_ip timer_state bot_state api_state interval zone_id records_block geo header
  record_type="${RECORD_TYPE:-A}"
  public_ip="$(get_public_ip "$record_type")"   # 失败时本函数已输出「未知」
  timer_state="$(systemctl is-active cf-ddns.timer 2>/dev/null || printf 'unknown')"
  bot_state="$(systemctl is-active cf-ddns-bot.service 2>/dev/null || printf 'unknown')"
  interval="$(timer_interval)"
  api_state="未启用"
  [[ "${IP_CHANGE_ENABLED:-false}" == "true" && -n "${IP_CHANGE_API_URL:-}" ]] && api_state="已启用"
  zone_id="$(cf_zone_id 2>/dev/null || true)"
  records_block="$(render_records_block "$zone_id" "$record_type" "$public_ip")"
  [[ -n "$records_block" ]] || records_block="🧭 记录 | 未配置"
  geo="$(geo_lookup "$public_ip" 2>/dev/null || true)"

  header="🚀 <b>Cloudflare DDNS 控制面板</b>"$'\n\n'
  header+="🌐 公网 IP（${record_type}）| <code>$(html_escape "$public_ip")</code>"$'\n'
  [[ -n "$geo" ]] && header+="🌍 IP 归属 | $(html_escape "$geo")"$'\n'
  header+="${records_block}"$'\n'
  header+="🔁 换 IP API | ${api_state}"$'\n'
  header+="⏱️ 定时器 | ${timer_state}（每 $(html_escape "$interval")）"$'\n'
  header+="🤖 Bot | ${bot_state}"$'\n'
  header+="🕒 刷新于 | $(date '+%H:%M:%S')"

  printf '%s' "$header"
}

panel_caption() {
  local note="${1:-面板就绪}"
  local force="${2:-}"
  local header now mtime age

  now="$(date +%s)"
  if [[ "$force" != "force" && -f "$HEADER_CACHE_FILE" ]]; then
    mtime="$(stat -c %Y "$HEADER_CACHE_FILE" 2>/dev/null || printf '0')"
    age=$((now - mtime))
    if [[ "$age" -ge 0 && "$age" -lt "$HEADER_CACHE_TTL" ]]; then
      header="$(cat "$HEADER_CACHE_FILE" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "${header:-}" ]]; then
    header="$(build_panel_header)"
    printf '%s' "$header" > "$HEADER_CACHE_FILE" 2>/dev/null || true
  fi

  printf '%s\n\n📌 当前操作 | %s\n\n请选择下方按钮操作：' "$header" "$(html_escape "$note")"
}

invalidate_header_cache() {
  rm -f "$HEADER_CACHE_FILE" 2>/dev/null || true
}

send_panel_response() {
  local chat_id="$1"
  local note="${2:-面板就绪}"
  local caption reply_markup image_file response

  caption="$(panel_caption "$note")"
  reply_markup="$(panel_markup)"
  image_file="$(resolve_panel_image_file)"

  if [[ -n "$image_file" && -f "$image_file" ]]; then
    if response="$(send_photo_response "$chat_id" "$caption" "$reply_markup" "$image_file")"; then
      printf '%s\n' "$response"
    else
      log_only "Telegram 图片面板发送失败，已改发文字面板。"
      send_panel_text_response "$chat_id" "$caption"
    fi
  else
    log_only "未找到面板图片，已改发文字面板。"
    send_panel_text_response "$chat_id" "$caption"
  fi
}

send_panel() {
  local chat_id="$1"
  local note="${2:-面板就绪}"

  send_panel_response "$chat_id" "$note" >/dev/null || log "Telegram 控制面板发送失败。"
}

open_panel_context() {
  local chat_id="$1"
  local note="$2"
  local response message_id message_kind

  response="$(send_panel_response "$chat_id" "$note" 2>/dev/null || true)"
  message_id="$(jq -r '.result.message_id // empty' <<<"$response" 2>/dev/null || true)"
  message_kind="text"
  if [[ "$(jq -r '(.result.photo // []) | length' <<<"$response" 2>/dev/null || printf '0')" -gt 0 ]]; then
    message_kind="photo"
  fi

  printf '%s\t%s\n' "$message_id" "$message_kind"
}

edit_panel() {
  local chat_id="$1"
  local message_id="$2"
  local message_kind="$3"
  local note="$4"
  local caption payload

  caption="$(panel_caption "$note")"

  if [[ -z "$message_id" ]]; then
    send_panel "$chat_id" "$note"
    return 0
  fi

  if [[ "$message_kind" == "photo" ]]; then
    payload="$(jq -n \
      --arg chat_id "$chat_id" \
      --argjson message_id "$message_id" \
      --arg caption "$caption" \
      --argjson reply_markup "$(panel_markup)" \
      '{chat_id:$chat_id,message_id:$message_id,caption:$caption,parse_mode:"HTML",reply_markup:$reply_markup}')"
    send_json editMessageCaption "$payload"
  else
    payload="$(jq -n \
      --arg chat_id "$chat_id" \
      --argjson message_id "$message_id" \
      --arg text "$caption" \
      --argjson reply_markup "$(panel_markup)" \
      '{chat_id:$chat_id,message_id:$message_id,text:$text,parse_mode:"HTML",reply_markup:$reply_markup}')"
    send_json editMessageText "$payload"
  fi
}

command_name() {
  local text="$1"
  local first="${text%% *}"
  first="${first%%@*}"
  printf '%s\n' "$first"
}

handle_changeip_panel() {
  local chat_id="$1"
  local message_id="$2"
  local message_kind="$3"
  local output wait_seconds

  if [[ "${IP_CHANGE_ENABLED:-false}" != "true" || -z "${IP_CHANGE_API_URL:-}" ]]; then
    edit_panel "$chat_id" "$message_id" "$message_kind" "换 IP API 未启用，请先在服务器执行 sudo ddns 配置。"
    return 0
  fi

  exec 8>"$BOT_LOCK_FILE"
  if ! flock -n 8; then
    edit_panel "$chat_id" "$message_id" "$message_kind" "已有任务正在运行，请稍后再试。"
    return 0
  fi

  edit_panel "$chat_id" "$message_id" "$message_kind" "正在请求换 IP API..."
  if output="$(bash "$CHANGER" 2>&1)"; then
    log "Telegram 换 IP API 输出：$output"
    wait_seconds="${IP_CHANGE_WAIT_SECONDS:-8}"
    [[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds="8"
    edit_panel "$chat_id" "$message_id" "$message_kind" "换 IP API 已完成，等待 ${wait_seconds} 秒后更新 DDNS..."
    sleep "$wait_seconds"
    invalidate_header_cache
    edit_panel "$chat_id" "$message_id" "$message_kind" "正在更新 Cloudflare DDNS..."
    if output="$(bash "$WORKER" 2>&1)"; then
      log "Telegram 换 IP 后 DDNS 输出：$output"
      invalidate_header_cache
      edit_panel "$chat_id" "$message_id" "$message_kind" "换 IP 与 DDNS 更新完成。"
    else
      log "Telegram 换 IP 后 DDNS 失败：$output"
      edit_panel "$chat_id" "$message_id" "$message_kind" "换 IP 已完成，但 DDNS 更新失败，请查看服务器日志。"
    fi
  else
    log "Telegram 换 IP API 失败：$output"
    edit_panel "$chat_id" "$message_id" "$message_kind" "换 IP API 请求失败，请查看服务器日志。"
  fi
}

handle_ddns_panel() {
  local chat_id="$1"
  local message_id="$2"
  local message_kind="$3"
  local output

  exec 8>"$BOT_LOCK_FILE"
  if ! flock -n 8; then
    edit_panel "$chat_id" "$message_id" "$message_kind" "已有任务正在运行，请稍后再试。"
    return 0
  fi

  edit_panel "$chat_id" "$message_id" "$message_kind" "正在立即运行 DDNS 检测..."
  if output="$(bash "$WORKER" 2>&1)"; then
    log "Telegram 手动 DDNS 输出：$output"
    invalidate_header_cache
    edit_panel "$chat_id" "$message_id" "$message_kind" "DDNS 检测完成。"
  else
    log "Telegram 手动 DDNS 失败：$output"
    edit_panel "$chat_id" "$message_id" "$message_kind" "DDNS 检测失败，请查看服务器日志。"
  fi
}

handle_refresh_panel() {
  local chat_id="$1"
  local message_id="$2"
  local message_kind="$3"

  invalidate_header_cache
  edit_panel "$chat_id" "$message_id" "$message_kind" "状态已刷新。"
}

handle_timer_toggle() {
  local chat_id="$1"
  local message_id="$2"
  local message_kind="$3"
  local action="$4"
  local note

  if [[ "$action" == "on" ]]; then
    if systemctl enable --now cf-ddns.timer >/dev/null 2>&1; then
      note="定时器已启用。"
    else
      note="启用定时器失败（需要 root 权限）。"
    fi
  else
    if systemctl disable --now cf-ddns.timer >/dev/null 2>&1; then
      note="定时器已停用。"
    else
      note="停用定时器失败（需要 root 权限）。"
    fi
  fi

  invalidate_header_cache
  edit_panel "$chat_id" "$message_id" "$message_kind" "$note"
}

handle_log() {
  local chat_id="$1"
  local lines

  if [[ -f "$LOG_FILE" ]]; then
    lines="$(tail -n 15 "$LOG_FILE" 2>/dev/null || true)"
  fi
  [[ -n "${lines:-}" ]] || lines="暂无日志。"

  send_html_message "$chat_id" "$(printf '📜 <b>最近日志（15 行）</b>\n<pre>%s</pre>' "$(html_escape "$lines")")"
}

handle_help_panel() {
  local chat_id="$1"
  local message_id="$2"
  local message_kind="$3"

  edit_panel "$chat_id" "$message_id" "$message_kind" \
    "换 IP=调用 API 并更新 DDNS；更新 DDNS=只检测 DNS；刷新=更新状态；日志=最近 15 行；定时器=启用/停用自动检测。"
}

handle_changeip_command() {
  local chat_id="$1"
  local context message_id message_kind

  context="$(open_panel_context "$chat_id" "正在准备换 IP...")"
  message_id="${context%%$'\t'*}"
  message_kind="${context##*$'\t'}"
  if [[ -z "$message_id" ]]; then
    send_message "$chat_id" "无法创建控制面板，请发送 /panel 后点击「换 IP」。"
    return 0
  fi
  handle_changeip_panel "$chat_id" "$message_id" "$message_kind"
}

handle_ddns_command() {
  local chat_id="$1"
  local context message_id message_kind

  context="$(open_panel_context "$chat_id" "正在准备 DDNS 检测...")"
  message_id="${context%%$'\t'*}"
  message_kind="${context##*$'\t'}"
  if [[ -z "$message_id" ]]; then
    send_message "$chat_id" "无法创建控制面板，请发送 /panel 后点击「更新 DDNS」。"
    return 0
  fi
  handle_ddns_panel "$chat_id" "$message_id" "$message_kind"
}

handle_callback_update() {
  local update="$1"
  local callback_id chat_id message_id message_kind data

  callback_id="$(jq -r '.callback_query.id // empty' <<<"$update")"
  chat_id="$(jq -r '.callback_query.message.chat.id // empty' <<<"$update")"
  message_id="$(jq -r '.callback_query.message.message_id // empty' <<<"$update")"
  message_kind="text"
  if [[ "$(jq -r '(.callback_query.message.photo // []) | length' <<<"$update")" -gt 0 ]]; then
    message_kind="photo"
  fi
  data="$(jq -r '.callback_query.data // empty' <<<"$update")"

  [[ -n "$callback_id" && -n "$chat_id" && -n "$message_id" && -n "$data" ]] || return 1

  if [[ "$chat_id" != "$TG_CHAT_ID" ]]; then
    log "已忽略未授权 Telegram Callback Chat ID：$chat_id"
    answer_callback_query "$callback_id" "未授权"
    return 0
  fi

  case "$data" in
    changeip)
      answer_callback_query "$callback_id" "正在换 IP"
      handle_changeip_panel "$chat_id" "$message_id" "$message_kind"
      ;;
    ddns)
      answer_callback_query "$callback_id" "正在更新 DDNS"
      handle_ddns_panel "$chat_id" "$message_id" "$message_kind"
      ;;
    refresh|status)
      answer_callback_query "$callback_id" "状态已刷新"
      handle_refresh_panel "$chat_id" "$message_id" "$message_kind"
      ;;
    log)
      answer_callback_query "$callback_id" "正在拉取日志"
      handle_log "$chat_id"
      ;;
    timer_on)
      answer_callback_query "$callback_id" "正在启用定时器"
      handle_timer_toggle "$chat_id" "$message_id" "$message_kind" "on"
      ;;
    timer_off)
      answer_callback_query "$callback_id" "正在停用定时器"
      handle_timer_toggle "$chat_id" "$message_id" "$message_kind" "off"
      ;;
    help)
      answer_callback_query "$callback_id" "帮助"
      handle_help_panel "$chat_id" "$message_id" "$message_kind"
      ;;
    panel)
      answer_callback_query "$callback_id" "已刷新"
      handle_refresh_panel "$chat_id" "$message_id" "$message_kind"
      ;;
    *) send_message "$chat_id" "未知按钮。发送 /panel 重新打开控制面板。" ;;
  esac

  return 0
}

handle_update() {
  local update="$1"
  local chat_id text cmd

  handle_callback_update "$update" && return 0

  chat_id="$(jq -r '.message.chat.id // .edited_message.chat.id // empty' <<<"$update")"
  text="$(jq -r '.message.text // .edited_message.text // empty' <<<"$update")"

  [[ -n "$chat_id" && -n "$text" ]] || return 0

  if [[ "$chat_id" != "$TG_CHAT_ID" ]]; then
    log "已忽略未授权 Telegram Chat ID：$chat_id"
    return 0
  fi

  cmd="$(command_name "$text")"
  case "$cmd" in
    /start|/panel) send_panel "$chat_id" ;;
    /changeip) handle_changeip_command "$chat_id" ;;
    /ddns) handle_ddns_command "$chat_id" ;;
    /status) invalidate_header_cache; send_panel "$chat_id" "状态已刷新。" ;;
    /log) handle_log "$chat_id" ;;
    /help) send_panel "$chat_id" "按钮说明：换 IP、更新 DDNS、刷新、日志、定时器开关都在面板内。" ;;
    "🔁 换 IP") handle_changeip_command "$chat_id" ;;
    "📡 更新 DDNS") handle_ddns_command "$chat_id" ;;
    "🔄 刷新") invalidate_header_cache; send_panel "$chat_id" "状态已刷新。" ;;
    "📜 日志") handle_log "$chat_id" ;;
    "ℹ️ 帮助") send_panel "$chat_id" "按钮说明：换 IP、更新 DDNS、刷新、日志、定时器开关都在面板内。" ;;
    *) send_message "$chat_id" "未知命令。发送 /panel 打开控制面板。" ;;
  esac
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd flock
  load_config

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  if [[ "${1:-}" == "--send-panel" ]]; then
    shift
    invalidate_header_cache
    send_panel "$TG_CHAT_ID" "${*:-面板就绪}"
    exit 0
  fi

  configure_bot_commands
  log "Telegram Bot 命令服务已启动。"

  local offset_file="$BASE_DIR/tg_bot.offset"
  local offset="0"
  [[ -f "$offset_file" ]] && offset="$(<"$offset_file")"

  # 网络抖动时静默退避重试，避免日志被「getUpdates 失败」刷屏：
  # 仅在首次失败时记一条，之后静默；恢复后再记一条。退避 5→10→20→40→60 秒封顶。
  local fail_count=0 backoff=5
  while true; do
    load_config

    local response update_ids update_id update
    if ! response="$(tg_api getUpdates --get --data-urlencode "timeout=25" --data-urlencode "offset=${offset}")"; then
      fail_count=$((fail_count + 1))
      if [[ "$fail_count" -eq 1 ]]; then
        log "Telegram getUpdates 连接失败，正在自动重试（后续静默，恢复后提示）。"
      fi
      sleep "$backoff"
      backoff=$((backoff * 2))
      [[ "$backoff" -gt 60 ]] && backoff=60
      continue
    fi

    if [[ "$fail_count" -gt 0 ]]; then
      log "Telegram getUpdates 已恢复（累计失败 ${fail_count} 次）。"
      fail_count=0
      backoff=5
    fi

    while IFS= read -r update; do
      [[ -n "$update" ]] || continue
      update_id="$(jq -r '.update_id' <<<"$update")"
      handle_update "$update"
      offset="$((update_id + 1))"
      printf '%s\n' "$offset" > "$offset_file"
    done < <(jq -c '.result[]?' <<<"$response")
  done
}

main "$@"
