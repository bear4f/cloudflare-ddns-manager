#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
LOG_FILE="/var/log/cf_ddns.log"
LOCK_FILE="/run/cf-ddns.lock"
BOT_WORKER="$BASE_DIR/cf_ddns_bot.sh"
CF_API_BASE="https://api.cloudflare.com/client/v4"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-2097152}"   # 2 MiB，超过则只保留最后 1000 行

# 公网 IP 检测的整组重试：换 IP 瞬间出口 NAT 链路会短暂重建，
# 单次查询很容易失败。整组数据源轮询失败后等待数秒再重试，
# 避免一次网络空窗就让本轮检测整轮作废。
IP_LOOKUP_ROUNDS="${IP_LOOKUP_ROUNDS:-3}"
IP_LOOKUP_RETRY_GAP="${IP_LOOKUP_RETRY_GAP:-3}"

# 公网 IP 数据源（多源容错，任一可用即可）。
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
  # 控制台副本写到 stderr：update_one_record 通过 $(...) 捕获 stdout 来判断
  # “本条记录是否有变更”，若 log 也写 stdout，未变化的“IP 未变化”日志会被
  # 误当成变更，导致每轮都推送面板。写到 stderr 即可两不相扰（日志文件照常写入）。
  printf '[%s] %s\n' "$(date '+%F %T')" "$message" | tee -a "$LOG_FILE" >&2
}

die() {
  log "错误：$1"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"
}

# 日志轮转：超过上限只保留最后 1000 行，避免无限增长。
cap_log_file() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size="$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  if [[ "$size" -gt "$MAX_LOG_BYTES" ]]; then
    local tmp
    tmp="$(mktemp)"
    tail -n 1000 "$LOG_FILE" > "$tmp" 2>/dev/null || true
    cat "$tmp" > "$LOG_FILE" 2>/dev/null || true
    rm -f "$tmp"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
}

send_telegram() {
  local text="$1"

  if [[ "${TG_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    log "Telegram 已启用但配置不完整，跳过推送。"
    return 0
  fi

  if ! curl -fsS --retry 3 --connect-timeout 5 --max-time 20 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$text" \
    >/dev/null; then
    log "Telegram 推送失败。"
  fi
}

send_telegram_panel() {
  local note="$1"

  if [[ "${TG_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  if [[ -x "$BOT_WORKER" ]]; then
    if bash "$BOT_WORKER" --send-panel "$note" >/dev/null 2>&1; then
      return 0
    fi
    log "Telegram 面板推送失败，改发普通文字通知。"
  fi

  send_telegram "$note"
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -fsS --retry 3 --connect-timeout 8 --max-time 30 \
      -X "$method" "$CF_API_BASE$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsS --retry 3 --connect-timeout 8 --max-time 30 \
      -X "$method" "$CF_API_BASE$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

json_success() {
  jq -e '.success == true' >/dev/null
}

urlencode() {
  jq -rn --arg value "$1" '$value|@uri'
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }

# 根据记录类型获取公网 IP，多源轮询并整组重试。
# 失败时只返回非 0（不调用 die），由 main 跳过本轮并等待下个周期重试，
# 避免一次瞬时网络抖动直接中止整个脚本（set -e）而废掉整轮检测。
get_public_ip() {
  local record_type="${1:-A}"
  local sources=() curl_proto ip src round

  if [[ "$record_type" == "AAAA" ]]; then
    sources=("${PUBLIC_IP6_SOURCES[@]}")
    curl_proto="-6"
  else
    sources=("${PUBLIC_IP4_SOURCES[@]}")
    curl_proto="-4"
  fi

  for ((round = 1; round <= IP_LOOKUP_ROUNDS; round++)); do
    for src in "${sources[@]}"; do
      ip="$(curl -fsS "$curl_proto" --retry 2 --connect-timeout 5 --max-time 10 "$src" 2>/dev/null | tr -d '[:space:]')" || true
      if [[ "$record_type" == "AAAA" ]]; then
        is_ipv6 "$ip" && { printf '%s\n' "$ip"; return 0; }
      else
        is_ipv4 "$ip" && { printf '%s\n' "$ip"; return 0; }
      fi
    done
    [[ "$round" -lt "$IP_LOOKUP_ROUNDS" ]] && sleep "$IP_LOOKUP_RETRY_GAP"
  done

  # 注意：重定向到 stderr，避免污染调用处 $(get_public_ip) 捕获的标准输出。
  log "无法从任一数据源获取有效公网 ${record_type} 地址（已重试 ${IP_LOOKUP_ROUNDS} 轮）。" >&2
  return 1
}

# 把 RECORD_NAME 拆成数组（支持逗号/空格分隔的多条记录）。
split_records() {
  local raw="$1"
  raw="${raw//,/ }"
  printf '%s\n' $raw
}

# 更新单条记录；输出一行变更摘要供汇总，未变化则不输出。
update_one_record() {
  local zone_id="$1" record_name="$2" record_type="$3" current_ip="$4"
  local record_query record_resp record_id old_ip payload resp

  record_query="$(urlencode "$record_name")"
  record_resp="$(cf_api GET "/zones/${zone_id}/dns_records?type=${record_type}&name=${record_query}")" \
    || { log "查询 DNS 记录失败：$record_name"; return 1; }
  printf '%s' "$record_resp" | json_success \
    || { log "DNS 记录查询未成功（$record_name）：$(printf '%s' "$record_resp" | jq -r '.errors[0].message // "未知错误"')"; return 1; }

  record_id="$(printf '%s' "$record_resp" | jq -r '.result[0].id // empty')"
  old_ip="$(printf '%s' "$record_resp" | jq -r '.result[0].content // empty')"

  payload="$(jq -n \
    --arg type "$record_type" \
    --arg name "$record_name" \
    --arg content "$current_ip" \
    --argjson ttl "${TTL:-120}" \
    --argjson proxied "${PROXY:-false}" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"

  if [[ -z "$record_id" ]]; then
    resp="$(cf_api POST "/zones/${zone_id}/dns_records" "$payload")" \
      || { log "创建 DNS 记录失败：$record_name"; return 1; }
    printf '%s' "$resp" | json_success \
      || { log "创建 DNS 记录未成功（$record_name）：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"')"; return 1; }
    log "已创建 $record_name -> $current_ip"
    printf '已创建 %s -> %s\n' "$record_name" "$current_ip"
    return 0
  fi

  if [[ "$old_ip" == "$current_ip" ]]; then
    log "$record_name IP 未变化：$current_ip"
    return 0
  fi

  resp="$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")" \
    || { log "更新 DNS 记录失败：$record_name"; return 1; }
  printf '%s' "$resp" | json_success \
    || { log "更新 DNS 记录未成功（$record_name）：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"')"; return 1; }
  log "已更新 $record_name：$old_ip -> $current_ip"
  printf '已更新 %s：%s -> %s\n' "$record_name" "$old_ip" "$current_ip"
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd flock

  [[ -f "$ENV_FILE" ]] || die "找不到配置文件：$ENV_FILE，请先执行 ddns 初始化配置。"
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  local record_type="${RECORD_TYPE:-A}"
  [[ "$record_type" == "A" || "$record_type" == "AAAA" ]] || die "RECORD_TYPE 必须是 A 或 AAAA。"

  [[ -n "${CF_API_TOKEN:-}" ]] || die "CF_API_TOKEN 不能为空。"
  [[ -n "${ZONE_NAME:-}" ]] || die "ZONE_NAME 不能为空。"
  [[ -n "${RECORD_NAME:-}" ]] || die "RECORD_NAME 不能为空。"
  [[ "${TTL:-120}" =~ ^[0-9]+$ ]] || die "TTL 必须是数字。"
  [[ "${PROXY:-false}" == "true" || "${PROXY:-false}" == "false" ]] || die "PROXY 必须是 true 或 false。"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有一个 DDNS 任务正在运行。"

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  cap_log_file

  local current_ip zone_query zone_resp zone_id
  if ! current_ip="$(get_public_ip "$record_type")"; then
    log "本轮 DDNS 跳过：暂时无法获取公网 ${record_type} 地址，等待下个周期重试。"
    return 0
  fi
  zone_query="$(urlencode "$ZONE_NAME")"

  zone_resp="$(cf_api GET "/zones?name=${zone_query}&status=active")" || die "查询 Cloudflare Zone 失败。"
  printf '%s' "$zone_resp" | json_success || die "Cloudflare Zone 查询未成功：$(printf '%s' "$zone_resp" | jq -r '.errors[0].message // "未知错误"')"
  zone_id="$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty')"
  [[ -n "$zone_id" ]] || die "未找到 Zone：$ZONE_NAME"

  local -a records=()
  local _r
  while IFS= read -r _r; do
    [[ -n "$_r" ]] && records+=("$_r")
  done < <(split_records "$RECORD_NAME")

  [[ "${#records[@]}" -gt 0 ]] || die "RECORD_NAME 解析后为空。"

  local changes="" line rc=0
  local record
  for record in "${records[@]}"; do
    [[ -n "$record" ]] || continue
    if line="$(update_one_record "$zone_id" "$record" "$record_type" "$current_ip")"; then
      [[ -n "$line" ]] && changes+="${line}"$'\n'
    else
      rc=1
    fi
  done

  if [[ -n "$changes" ]]; then
    send_telegram_panel "DDNS 变更（$record_type）：
${changes%$'\n'}"
  fi

  return "$rc"
}

main "$@"
