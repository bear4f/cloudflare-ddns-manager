#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
LOG_FILE="/var/log/cf_ddns.log"
LOCK_FILE="/run/cf-change-ip.lock"

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

api_url_with_format() {
  local url="$1"

  if [[ "${IP_CHANGE_API_FORMAT_JSON:-true}" != "true" ]]; then
    printf '%s\n' "$url"
    return 0
  fi

  if [[ "$url" == *"format="* ]]; then
    printf '%s\n' "$url"
  elif [[ "$url" == *"?"* ]]; then
    printf '%s&format=json\n' "$url"
  else
    printf '%s?format=json\n' "$url"
  fi
}

summarize_response() {
  local response="$1"
  local summary=""

  if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <<<"$response"; then
    summary="$(jq -r '
      .message // .msg // .status // .code // .data.message // .data.msg // empty
    ' <<<"$response" | head -n 1)"
    if [[ -n "$summary" && "$summary" != "null" ]]; then
      printf '%s\n' "$summary"
    else
      printf 'API 已返回 JSON 结果。\n'
    fi
  else
    printf '%s\n' "$response" | head -c 400
    printf '\n'
  fi
}

main() {
  require_cmd curl
  require_cmd flock

  [[ -f "$ENV_FILE" ]] || die "找不到配置文件：$ENV_FILE，请先执行 ddns 初始化配置。"
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  [[ "${IP_CHANGE_ENABLED:-false}" == "true" ]] || die "换 IP API 未启用，请先执行 ddns 配置。"
  [[ -n "${IP_CHANGE_API_URL:-}" ]] || die "IP_CHANGE_API_URL 不能为空。"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有一个换 IP 任务正在运行。"

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  local request_url response summary
  request_url="$(api_url_with_format "$IP_CHANGE_API_URL")"

  log "正在请求换 IP API。"
  response="$(curl -fsS --retry 2 --connect-timeout 10 --max-time 90 "$request_url")" || die "换 IP API 请求失败。"
  summary="$(summarize_response "$response")"
  log "换 IP API 请求完成：$summary"
  printf '%s\n' "$summary"
}

main "$@"
