#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
WORKER="$BASE_DIR/cf_ddns.sh"
CHANGER="$BASE_DIR/cf_change_ip.sh"
LOG_FILE="/var/log/cf_ddns.log"
BOT_LOCK_FILE="/run/cf-ddns-bot-command.lock"
PANEL_IMAGE_FILE="${PANEL_IMAGE_FILE:-}"
MIN_PANEL_IMAGE_BYTES=1000

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

is_valid_panel_image() {
  local image_file="$1"
  local byte_count magic

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
      magic="$(LC_ALL=C od -An -N4 -tx1 "$image_file" 2>/dev/null | tr -d ' \n')"
      [[ "$magic" == "89504e47" ]]
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
  curl -fsS --retry 2 --connect-timeout 10 --max-time 60 \
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

send_json() {
  local method="$1"
  local payload="$2"

  tg_api "$method" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    >/dev/null || log "Telegram ${method} 请求失败。"
}

resolve_panel_image_file() {
  if [[ -n "${PANEL_IMAGE_FILE:-}" ]] && is_valid_panel_image "$PANEL_IMAGE_FILE"; then
    printf '%s\n' "$PANEL_IMAGE_FILE"
    return 0
  fi

  if is_valid_panel_image "$BASE_DIR/panel_illustration.jpg"; then
    printf '%s\n' "$BASE_DIR/panel_illustration.jpg"
  elif is_valid_panel_image "$BASE_DIR/panel_illustration.png"; then
    printf '%s\n' "$BASE_DIR/panel_illustration.png"
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
    '{chat_id:$chat_id,text:$text,reply_markup:$reply_markup}')"
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
      {command:"status", description:"查看状态"},
      {command:"help", description:"帮助"}
    ]
  }')"

  send_json setMyCommands "$payload"
}

panel_markup() {
  jq -cn '{
    inline_keyboard: [
      [
        {text:"🔁 换 IP", callback_data:"changeip"},
        {text:"📡 更新 DDNS", callback_data:"ddns"}
      ],
      [
        {text:"📊 状态", callback_data:"status"},
        {text:"ℹ️ 帮助", callback_data:"help"}
      ]
    ]
  }'
}

panel_caption() {
  local note="${1:-面板就绪}"
  local public_ip timer_state bot_state api_state updated_at

  public_ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || printf '未知')"
  timer_state="$(systemctl is-active cf-ddns.timer 2>/dev/null || true)"
  bot_state="$(systemctl is-active cf-ddns-bot.service 2>/dev/null || true)"
  api_state="未启用"
  [[ "${IP_CHANGE_ENABLED:-false}" == "true" && -n "${IP_CHANGE_API_URL:-}" ]] && api_state="已启用"
  updated_at="$(date '+%H:%M:%S')"

  printf '🚀 Cloudflare DDNS 控制面板\n\n🌐 当前公网 IP | %s\n🧭 DNS 记录 | %s\n🔁 换 IP API | %s\n⏱️ DDNS 定时器 | %s\n🤖 Bot 服务 | %s\n🕒 更新时间 | %s\n\n📌 当前操作 | %s\n\n请选择下方按钮操作：' \
    "$public_ip" \
    "${RECORD_NAME:-未配置}" \
    "$api_state" \
    "${timer_state:-unknown}" \
    "${bot_state:-unknown}" \
    "$updated_at" \
    "$note"
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
      '{chat_id:$chat_id,message_id:$message_id,caption:$caption,reply_markup:$reply_markup}')"
    send_json editMessageCaption "$payload"
  else
    payload="$(jq -n \
      --arg chat_id "$chat_id" \
      --argjson message_id "$message_id" \
      --arg text "$caption" \
      --argjson reply_markup "$(panel_markup)" \
      '{chat_id:$chat_id,message_id:$message_id,text:$text,reply_markup:$reply_markup}')"
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
    edit_panel "$chat_id" "$message_id" "$message_kind" "正在更新 Cloudflare DDNS..."
    if output="$(bash "$WORKER" 2>&1)"; then
      log "Telegram 换 IP 后 DDNS 输出：$output"
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
    edit_panel "$chat_id" "$message_id" "$message_kind" "DDNS 检测完成。"
  else
    log "Telegram 手动 DDNS 失败：$output"
    edit_panel "$chat_id" "$message_id" "$message_kind" "DDNS 检测失败，请查看服务器日志。"
  fi
}

handle_status_panel() {
  local chat_id="$1"
  local message_id="$2"
  local message_kind="$3"

  edit_panel "$chat_id" "$message_id" "$message_kind" "状态已刷新。"
}

handle_help_panel() {
  local chat_id="$1"
  local message_id="$2"
  local message_kind="$3"

  edit_panel "$chat_id" "$message_id" "$message_kind" "按钮说明：换 IP 会调用 API 并更新 DDNS；更新 DDNS 只检测 DNS；状态会刷新面板。"
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
    status)
      answer_callback_query "$callback_id" "状态已刷新"
      handle_status_panel "$chat_id" "$message_id" "$message_kind"
      ;;
    help)
      answer_callback_query "$callback_id" "帮助"
      handle_help_panel "$chat_id" "$message_id" "$message_kind"
      ;;
    panel)
      answer_callback_query "$callback_id" "已刷新"
      edit_panel "$chat_id" "$message_id" "$message_kind" "面板已刷新。"
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
    /status) send_panel "$chat_id" "状态已刷新。" ;;
    /help) send_panel "$chat_id" "按钮说明：换 IP、更新 DDNS、状态、帮助都在面板内刷新。" ;;
    "🔁 换 IP") handle_changeip_command "$chat_id" ;;
    "📡 更新 DDNS") handle_ddns_command "$chat_id" ;;
    "📊 状态") send_panel "$chat_id" "状态已刷新。" ;;
    "ℹ️ 帮助") send_panel "$chat_id" "按钮说明：换 IP、更新 DDNS、状态、帮助都在面板内刷新。" ;;
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
    send_panel "$TG_CHAT_ID" "${*:-面板就绪}"
    exit 0
  fi

  configure_bot_commands
  log "Telegram Bot 命令服务已启动。"

  local offset_file="$BASE_DIR/tg_bot.offset"
  local offset="0"
  [[ -f "$offset_file" ]] && offset="$(<"$offset_file")"

  while true; do
    load_config

    local response update_ids update_id update
    if ! response="$(tg_api getUpdates --get --data-urlencode "timeout=25" --data-urlencode "offset=${offset}")"; then
      log "Telegram getUpdates 失败，5 秒后重试。"
      sleep 5
      continue
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
