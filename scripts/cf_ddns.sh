#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
LOG_FILE="/var/log/cf_ddns.log"
LOCK_FILE="/run/cf-ddns.lock"
BOT_WORKER="$BASE_DIR/cf_ddns_bot.sh"
CF_API_BASE="https://api.cloudflare.com/client/v4"

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

get_public_ip() {
  local ip=""
  ip="$(curl -fsS --retry 3 --connect-timeout 5 --max-time 15 https://api.ipify.org || true)"

  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "无法获取有效公网 IPv4。"
  fi

  printf '%s\n' "$ip"
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd flock

  [[ -f "$ENV_FILE" ]] || die "找不到配置文件：$ENV_FILE，请先执行 ddns 初始化配置。"
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  [[ -n "${CF_API_TOKEN:-}" ]] || die "CF_API_TOKEN 不能为空。"
  [[ -n "${ZONE_NAME:-}" ]] || die "ZONE_NAME 不能为空。"
  [[ -n "${RECORD_NAME:-}" ]] || die "RECORD_NAME 不能为空。"
  [[ "${TTL:-120}" =~ ^[0-9]+$ ]] || die "TTL 必须是数字。"
  [[ "${PROXY:-false}" == "true" || "${PROXY:-false}" == "false" ]] || die "PROXY 必须是 true 或 false。"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有一个 DDNS 任务正在运行。"

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  local current_ip zone_query zone_resp zone_id record_query record_resp record_id old_ip payload resp
  current_ip="$(get_public_ip)"
  zone_query="$(urlencode "$ZONE_NAME")"
  record_query="$(urlencode "$RECORD_NAME")"

  zone_resp="$(cf_api GET "/zones?name=${zone_query}&status=active")" || die "查询 Cloudflare Zone 失败。"
  printf '%s' "$zone_resp" | json_success || die "Cloudflare Zone 查询未成功：$(printf '%s' "$zone_resp" | jq -r '.errors[0].message // "未知错误"')"
  zone_id="$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty')"
  [[ -n "$zone_id" ]] || die "未找到 Zone：$ZONE_NAME"

  record_resp="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${record_query}")" || die "查询 DNS 记录失败。"
  printf '%s' "$record_resp" | json_success || die "Cloudflare DNS 记录查询未成功：$(printf '%s' "$record_resp" | jq -r '.errors[0].message // "未知错误"')"

  record_id="$(printf '%s' "$record_resp" | jq -r '.result[0].id // empty')"
  old_ip="$(printf '%s' "$record_resp" | jq -r '.result[0].content // empty')"

  payload="$(jq -n \
    --arg type "A" \
    --arg name "$RECORD_NAME" \
    --arg content "$current_ip" \
    --argjson ttl "${TTL:-120}" \
    --argjson proxied "${PROXY:-false}" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"

  if [[ -z "$record_id" ]]; then
    resp="$(cf_api POST "/zones/${zone_id}/dns_records" "$payload")" || die "创建 DNS 记录失败。"
    printf '%s' "$resp" | json_success || die "创建 DNS 记录未成功：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"')"
    log "已创建 $RECORD_NAME -> $current_ip"
    send_telegram_panel "DDNS 已自动创建：$RECORD_NAME -> $current_ip"
    return 0
  fi

  if [[ "$old_ip" == "$current_ip" ]]; then
    log "$RECORD_NAME IP 未变化：$current_ip"
    return 0
  fi

  resp="$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")" || die "更新 DNS 记录失败。"
  printf '%s' "$resp" | json_success || die "更新 DNS 记录未成功：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"')"
  log "已更新 $RECORD_NAME：$old_ip -> $current_ip"
  send_telegram_panel "DDNS 已自动更新：$RECORD_NAME，$old_ip -> $current_ip"
}

main "$@"
