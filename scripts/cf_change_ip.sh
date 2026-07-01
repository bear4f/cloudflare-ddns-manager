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

CHANGE_IP_STATUS=""

# 默认新版 API 端点（Boil 已停用旧版 GET 链接，改为 POST + Bearer Token）。
DEFAULT_API_ENDPOINT="https://ippanel.boil.network/api/v1/changeIP"

# 发起换 IP 请求：新版传 token 走 POST + Authorization: Bearer；旧版留空 token 走 GET。
# 响应体写入 body_file，HTTP 状态码存入 CHANGE_IP_STATUS。2xx 返回 0。
# 必须直接调用（勿放进 $(...)），否则全局赋值会在子shell丢失。
change_ip_request() {
  local url="$1" body_file="$2" token="${3:-}"
  local -a args=(-sS --retry 2 --connect-timeout 10 --max-time 90 -o "$body_file" -w '%{http_code}')
  if [[ -n "$token" ]]; then
    args+=(-X POST -H "Authorization: Bearer ${token}")
  fi
  CHANGE_IP_STATUS="$(curl "${args[@]}" "$url" 2>/dev/null)" || CHANGE_IP_STATUS="000"
  [[ "$CHANGE_IP_STATUS" == 2* ]]
}

main() {
  require_cmd curl
  require_cmd flock

  [[ -f "$ENV_FILE" ]] || die "找不到配置文件：$ENV_FILE，请先执行 ddns 初始化配置。"
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  [[ "${IP_CHANGE_ENABLED:-false}" == "true" ]] || die "换 IP API 未启用，请先执行 ddns 配置。"

  local token="${IP_CHANGE_API_TOKEN:-}"
  local endpoint="${IP_CHANGE_API_ENDPOINT:-$DEFAULT_API_ENDPOINT}"

  [[ -n "$token" || -n "${IP_CHANGE_API_URL:-}" ]] \
    || die "换 IP API 未配置：请填写 IP_CHANGE_API_TOKEN（新版 Boil API Token）或旧版 IP_CHANGE_API_URL。"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有一个换 IP 任务正在运行。"

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  local body_file response summary body
  body_file="$(mktemp)"
  log "正在请求换 IP API。"

  if [[ -n "$token" ]]; then
    # 新版：POST /api/v1/changeIP + Authorization: Bearer <token>
    if ! change_ip_request "$endpoint" "$body_file" "$token"; then
      body="$(head -c 400 "$body_file" 2>/dev/null | tr -d '\r\n')"
      rm -f "$body_file"
      die "换 IP API 请求失败（HTTP ${CHANGE_IP_STATUS}）：${body:-无响应体，请确认 API Token 是否有效/未过期}"
    fi
  else
    # 旧版：GET url（Boil 已停用，保留兼容）；失败自动去掉 format=json 再试一次。
    local request_url
    request_url="$(api_url_with_format "$IP_CHANGE_API_URL")"
    if ! change_ip_request "$request_url" "$body_file"; then
      if [[ "$request_url" != "$IP_CHANGE_API_URL" ]]; then
        log "换 IP API 返回 HTTP ${CHANGE_IP_STATUS}，去掉 format=json 重试。"
        change_ip_request "$IP_CHANGE_API_URL" "$body_file" || true
      fi
      if [[ "$CHANGE_IP_STATUS" != 2* ]]; then
        body="$(head -c 400 "$body_file" 2>/dev/null | tr -d '\r\n')"
        rm -f "$body_file"
        die "换 IP API 请求失败（HTTP ${CHANGE_IP_STATUS}）：${body:-无响应体}。提示：Boil 旧版 GET API 已停用，请改用 API Token（sudo ddns → 1 重新配置）。"
      fi
    fi
  fi

  response="$(cat "$body_file" 2>/dev/null || true)"
  rm -f "$body_file"
  summary="$(summarize_response "$response")"
  log "换 IP API 请求完成：$summary"
  printf '%s\n' "$summary"
}

main "$@"
