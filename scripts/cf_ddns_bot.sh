#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
WORKER="$BASE_DIR/cf_ddns.sh"
CHANGER="$BASE_DIR/cf_change_ip.sh"
LOG_FILE="/var/log/cf_ddns.log"
BOT_LOCK_FILE="/run/cf-ddns-bot-command.lock"

log() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%F %T')" "$message" | tee -a "$LOG_FILE"
}

die() {
  log "错误：$1"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"
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

tail_log_text() {
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 12 "$LOG_FILE"
  else
    printf '暂无日志。\n'
  fi
}

command_name() {
  local text="$1"
  local first="${text%% *}"
  first="${first%%@*}"
  printf '%s\n' "$first"
}

handle_changeip() {
  local chat_id="$1"
  local output wait_seconds

  if [[ "${IP_CHANGE_ENABLED:-false}" != "true" || -z "${IP_CHANGE_API_URL:-}" ]]; then
    send_message "$chat_id" "换 IP API 未启用，请先在服务器执行 sudo ddns 进入配置。"
    return 0
  fi

  exec 8>"$BOT_LOCK_FILE"
  if ! flock -n 8; then
    send_message "$chat_id" "已有一个换 IP 或 DDNS 任务正在运行，请稍后再试。"
    return 0
  fi

  send_message "$chat_id" "收到 /changeip，正在请求换 IP API..."
  if output="$(bash "$CHANGER" 2>&1)"; then
    wait_seconds="${IP_CHANGE_WAIT_SECONDS:-8}"
    [[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds="8"
    send_message "$chat_id" "换 IP API 已完成：${output}
等待 ${wait_seconds} 秒后更新 Cloudflare DDNS..."
    sleep "$wait_seconds"
    if output="$(bash "$WORKER" 2>&1)"; then
      send_message "$chat_id" "DDNS 更新完成。

$(tail_log_text)"
    else
      send_message "$chat_id" "DDNS 更新失败：
${output}"
    fi
  else
    send_message "$chat_id" "换 IP API 请求失败：
${output}"
  fi
}

handle_ddns() {
  local chat_id="$1"
  local output

  exec 8>"$BOT_LOCK_FILE"
  if ! flock -n 8; then
    send_message "$chat_id" "已有一个换 IP 或 DDNS 任务正在运行，请稍后再试。"
    return 0
  fi

  send_message "$chat_id" "正在立即运行 DDNS 检测..."
  if output="$(bash "$WORKER" 2>&1)"; then
    send_message "$chat_id" "DDNS 检测完成。

$(tail_log_text)"
  else
    send_message "$chat_id" "DDNS 检测失败：
${output}"
  fi
}

handle_status() {
  local chat_id="$1"
  local public_ip timer_state bot_state

  public_ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || printf '未知')"
  timer_state="$(systemctl is-active cf-ddns.timer 2>/dev/null || true)"
  bot_state="$(systemctl is-active cf-ddns-bot.service 2>/dev/null || true)"

  send_message "$chat_id" "当前公网 IP：${public_ip}
DDNS timer：${timer_state:-unknown}
Telegram Bot：${bot_state:-unknown}
记录域名：${RECORD_NAME:-未配置}"
}

handle_help() {
  local chat_id="$1"
  send_message "$chat_id" "可用命令：
/changeip - 调用换 IP API，然后自动更新 Cloudflare DDNS
/ddns - 只立即运行一次 DDNS 检测
/status - 查看当前公网 IP 和服务状态
/help - 查看帮助"
}

handle_update() {
  local update="$1"
  local chat_id text cmd

  chat_id="$(jq -r '.message.chat.id // .edited_message.chat.id // empty' <<<"$update")"
  text="$(jq -r '.message.text // .edited_message.text // empty' <<<"$update")"

  [[ -n "$chat_id" && -n "$text" ]] || return 0

  if [[ "$chat_id" != "$TG_CHAT_ID" ]]; then
    log "已忽略未授权 Telegram Chat ID：$chat_id"
    return 0
  fi

  cmd="$(command_name "$text")"
  case "$cmd" in
    /changeip) handle_changeip "$chat_id" ;;
    /ddns) handle_ddns "$chat_id" ;;
    /status) handle_status "$chat_id" ;;
    /start|/help) handle_help "$chat_id" ;;
    *) send_message "$chat_id" "未知命令。发送 /help 查看可用命令。" ;;
  esac
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd flock
  load_config

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
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
