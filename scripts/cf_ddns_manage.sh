#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
WORKER="$BASE_DIR/cf_ddns.sh"
CHANGER="$BASE_DIR/cf_change_ip.sh"
BOT_WORKER="$BASE_DIR/cf_ddns_bot.sh"
LOG_FILE="/var/log/cf_ddns.log"
SERVICE_FILE="/etc/systemd/system/cf-ddns.service"
TIMER_FILE="/etc/systemd/system/cf-ddns.timer"
BOT_SERVICE_FILE="/etc/systemd/system/cf-ddns-bot.service"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 用户执行：ddns"
    exit 1
  fi
}

pause() {
  echo
  read -r -p "按回车返回菜单..." _ || true
}

load_env() {
  CF_API_TOKEN=""
  ZONE_NAME=""
  RECORD_NAME=""
  TTL="120"
  PROXY="false"
  TG_ENABLED="false"
  TG_BOT_TOKEN=""
  TG_CHAT_ID=""
  IP_CHANGE_ENABLED="false"
  IP_CHANGE_API_URL=""
  IP_CHANGE_API_FORMAT_JSON="true"
  IP_CHANGE_WAIT_SECONDS="8"

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || true
  fi
}

prompt_secret_keep() {
  local var="$1"
  local prompt="$2"
  local old="${!var:-}"
  local input=""

  if [[ -n "$old" ]]; then
    read -r -s -p "$prompt [已配置，回车保留；输入新值则覆盖]: " input || true
    echo
    if [[ -n "$input" ]]; then
      printf -v "$var" '%s' "$input"
    fi
  else
    while [[ -z "${!var:-}" ]]; do
      read -r -s -p "$prompt: " input || true
      echo
      if [[ -n "$input" ]]; then
        printf -v "$var" '%s' "$input"
      else
        echo "不能为空。"
      fi
    done
  fi
}

prompt_sensitive_text_keep() {
  local var="$1"
  local prompt="$2"
  local example="$3"
  local old="${!var:-}"
  local input=""

  if [[ -n "$old" ]]; then
    read -r -p "$prompt [已配置，回车保留；输入新值则覆盖，例如 ${example}]: " input || true
    if [[ -n "$input" ]]; then
      printf -v "$var" '%s' "$input"
    fi
  else
    while true; do
      read -r -p "$prompt，例如 ${example}: " input || true
      if [[ -n "$input" ]]; then
        printf -v "$var" '%s' "$input"
        return 0
      fi
      echo "不能为空。"
    done
  fi
}

prompt_num_keep() {
  local var="$1"
  local prompt="$2"
  local default_value="$3"
  local old="${!var:-$default_value}"
  local input=""

  while true; do
    read -r -p "$prompt [$old]: " input || true
    input="${input:-$old}"
    if [[ "$input" =~ ^[0-9]+$ && "$input" -ge 1 ]]; then
      printf -v "$var" '%s' "$input"
      return 0
    fi
    echo "请输入大于等于 1 的数字。"
  done
}

prompt_bool_keep() {
  local var="$1"
  local prompt="$2"
  local default_value="$3"
  local old="${!var:-$default_value}"
  local input=""

  case "$old" in
    true|false) ;;
    *) old="$default_value" ;;
  esac

  while true; do
    local hint="n"
    [[ "$old" == "true" ]] && hint="y"
    read -r -p "$prompt [${hint}]: " input || true
    input="${input:-$hint}"

    case "${input,,}" in
      y|yes|true|1)
        printf -v "$var" '%s' "true"
        return 0
        ;;
      n|no|false|0)
        printf -v "$var" '%s' "false"
        return 0
        ;;
      *)
        echo "请输入 y 或 n。"
        ;;
    esac
  done
}

save_env() {
  local tmp=""
  tmp="$(mktemp)"

  {
    cat <<'COMMENT_EOF'
# Cloudflare DDNS 配置文件
# 文件权限应保持 600：
# chmod 600 /usr/local/ddns/cf_ddns.env
#
# Cloudflare API Token 权限建议：
# Zone:Read + DNS:Edit，并尽量只限定到对应 Zone。
COMMENT_EOF

    printf 'CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
    printf 'ZONE_NAME=%q\n' "$ZONE_NAME"
    printf 'RECORD_NAME=%q\n' "$RECORD_NAME"
    printf 'TTL=%q\n' "$TTL"
    printf 'PROXY=%q\n' "$PROXY"

    echo

    cat <<'COMMENT_EOF'
# 换 IP API 配置
# IP_CHANGE_API_URL 通常是 Boil 面板生成的 https://ippanel.boil.network/api/... 专属链接。
# IP_CHANGE_API_FORMAT_JSON=true 时会自动给链接追加 format=json。
COMMENT_EOF

    printf 'IP_CHANGE_ENABLED=%q\n' "$IP_CHANGE_ENABLED"
    printf 'IP_CHANGE_API_URL=%q\n' "$IP_CHANGE_API_URL"
    printf 'IP_CHANGE_API_FORMAT_JSON=%q\n' "$IP_CHANGE_API_FORMAT_JSON"
    printf 'IP_CHANGE_WAIT_SECONDS=%q\n' "$IP_CHANGE_WAIT_SECONDS"

    echo

    cat <<'COMMENT_EOF'
# Telegram 通知配置
# TG_ENABLED=true 时，仅在 DNS 记录创建或 IP 变化更新成功后推送。
# 安装 Telegram Bot 命令服务后，可通过 /changeip 触发换 IP API。
COMMENT_EOF

    printf 'TG_ENABLED=%q\n' "$TG_ENABLED"
    printf 'TG_BOT_TOKEN=%q\n' "$TG_BOT_TOKEN"
    printf 'TG_CHAT_ID=%q\n' "$TG_CHAT_ID"
  } > "$tmp"

  install -m 600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"

  chmod 700 "$BASE_DIR"
  echo "已保存配置：$ENV_FILE"
}

ensure_deps() {
  local missing=()
  local cmd=""

  for cmd in curl jq flock; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  echo "缺少依赖：${missing[*]}"

  if command -v apt-get >/dev/null 2>&1; then
    read -r -p "是否自动安装 curl jq util-linux ca-certificates？[Y/n]: " ans || true
    ans="${ans:-Y}"

    case "${ans,,}" in
      y|yes)
        apt-get update
        apt-get install -y curl jq util-linux ca-certificates
        ;;
      *)
        echo "已取消自动安装。"
        return 1
        ;;
    esac
  else
    echo "未检测到 apt-get，请手动安装：curl jq util-linux ca-certificates"
    return 1
  fi
}

configure_env() {
  load_env

  echo
  echo "=== Cloudflare DDNS 配置 ==="
  echo "说明：下面不会回显已保存的真实域名、记录名或密钥。"
  echo

  prompt_secret_keep CF_API_TOKEN "请输入 Cloudflare API Token"
  prompt_sensitive_text_keep ZONE_NAME "请输入 Cloudflare Zone Name" "example.com"
  prompt_sensitive_text_keep RECORD_NAME "请输入需要 DDNS 更新的完整 A 记录域名" "ddns.example.com"
  prompt_num_keep TTL "请输入 TTL，常用 120；若使用 Cloudflare 自动 TTL 可填 1" "${TTL:-120}"
  prompt_bool_keep PROXY "是否开启 Cloudflare 小云朵代理 proxied？DDNS 通常建议 n" "${PROXY:-false}"

  echo
  echo "=== Boil 换 IP API ==="
  echo "如果已获得专属 API，可在这里配置；脚本会把链接作为密钥保存，不会回显。"
  echo

  prompt_bool_keep IP_CHANGE_ENABLED "是否启用换 IP API？" "${IP_CHANGE_ENABLED:-false}"

  if [[ "$IP_CHANGE_ENABLED" == "true" ]]; then
    prompt_secret_keep IP_CHANGE_API_URL "请输入换 IP API 专属链接"
    prompt_bool_keep IP_CHANGE_API_FORMAT_JSON "是否自动追加 format=json？通常建议 y" "${IP_CHANGE_API_FORMAT_JSON:-true}"
    prompt_num_keep IP_CHANGE_WAIT_SECONDS "换 IP 后等待多少秒再更新 Cloudflare DDNS" "${IP_CHANGE_WAIT_SECONDS:-8}"
  else
    IP_CHANGE_API_URL=""
    IP_CHANGE_API_FORMAT_JSON="true"
    IP_CHANGE_WAIT_SECONDS="8"
  fi

  echo
  echo "=== Telegram 变更通知 ==="
  echo "如需推送："
  echo "1. 在 Telegram 搜索 @BotFather"
  echo "2. 发送 /newbot 创建机器人并获得 Bot Token"
  echo "3. 先给机器人发一条消息"
  echo "4. 使用 getUpdates 获取 chat_id"
  echo "5. 群组通知则需先把机器人拉进群"
  echo

  prompt_bool_keep TG_ENABLED "是否启用 Telegram 通知？" "${TG_ENABLED:-false}"

  if [[ "$TG_ENABLED" == "true" ]]; then
    prompt_secret_keep TG_BOT_TOKEN "请输入 Telegram Bot Token"
    prompt_sensitive_text_keep TG_CHAT_ID "请输入 Telegram Chat ID" "123456789"
  else
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
  fi

  save_env
}

install_timer() {
  ensure_deps || return 1

  local minutes="2"
  read -r -p "请输入检测间隔，单位分钟 [2]: " minutes || true
  minutes="${minutes:-2}"

  if ! [[ "$minutes" =~ ^[0-9]+$ && "$minutes" -ge 1 ]]; then
    echo "间隔必须是大于等于 1 的数字。"
    return 1
  fi

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare DDNS Update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$WORKER
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Cloudflare DDNS every ${minutes} minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=${minutes}min
AccuracySec=30s
Persistent=true
Unit=cf-ddns.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now cf-ddns.timer
  systemctl restart cf-ddns.timer

  echo "已安装/更新定时器：每 ${minutes} 分钟检测一次。"
  systemctl list-timers --all | grep -E 'cf-ddns|NEXT' || true
}

run_once() {
  ensure_deps || return 1

  if [[ ! -f "$ENV_FILE" ]]; then
    echo "尚未配置，请先选择 1 初始化/修改配置。"
    return 1
  fi

  bash "$WORKER"
}

change_ip_once() {
  ensure_deps || return 1

  if [[ ! -f "$ENV_FILE" ]]; then
    echo "尚未配置，请先选择 1 初始化/修改配置。"
    return 1
  fi

  load_env

  if [[ "${IP_CHANGE_ENABLED:-false}" != "true" || -z "${IP_CHANGE_API_URL:-}" ]]; then
    echo "换 IP API 未启用或配置不完整，请先选择 1 修改配置。"
    return 1
  fi

  bash "$CHANGER"

  local wait_seconds="${IP_CHANGE_WAIT_SECONDS:-8}"
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds="8"

  echo "等待 ${wait_seconds} 秒后运行一次 DDNS 检测..."
  sleep "$wait_seconds"
  bash "$WORKER"
}

install_bot_service() {
  ensure_deps || return 1
  load_env

  if [[ "${TG_ENABLED:-false}" != "true" || -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo "Telegram 未启用或配置不完整，请先选择 1 修改配置。"
    return 1
  fi

  cat > "$BOT_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare DDNS Telegram Command Bot
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$BOT_WORKER
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cf-ddns-bot.service
  systemctl restart cf-ddns-bot.service

  echo "已安装/更新 Telegram Bot 命令服务。"
  echo "可用命令：/changeip /ddns /status /help"
  systemctl status cf-ddns-bot.service --no-pager || true
}

test_telegram() {
  ensure_deps || return 1
  load_env

  if [[ "${TG_ENABLED:-false}" != "true" || -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo "Telegram 未启用或配置不完整，请先选择 1 修改配置。"
    return 1
  fi

  if curl -fsS --retry 3 --connect-timeout 5 --max-time 20 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=Cloudflare DDNS Telegram 测试推送：$(date '+%F %T')" \
    >/dev/null; then
    echo "Telegram 测试推送成功。"
  else
    echo "Telegram 测试推送失败，请检查 Bot Token、Chat ID、机器人对话或群组权限。"
    return 1
  fi
}

show_status() {
  echo
  echo "=== systemd timer ==="
  systemctl status cf-ddns.timer --no-pager || true

  echo
  echo "=== last service run ==="
  systemctl status cf-ddns.service --no-pager || true

  echo
  echo "=== telegram bot service ==="
  systemctl status cf-ddns-bot.service --no-pager || true

  echo
  echo "注意：DDNS 日志可能包含真实域名、旧 IP、新 IP。"
  read -r -p "是否显示最近 80 行日志？[y/N]: " ans || true
  ans="${ans:-N}"

  case "${ans,,}" in
    y|yes)
      echo
      echo "=== recent log: $LOG_FILE ==="
      if [[ -f "$LOG_FILE" ]]; then
        tail -n 80 "$LOG_FILE"
      else
        echo "暂无日志。"
      fi
      ;;
    *)
      echo "已跳过日志显示。"
      ;;
  esac
}

disable_timer() {
  systemctl disable --now cf-ddns.timer 2>/dev/null || true
  systemctl daemon-reload
  echo "已停用 cf-ddns.timer；配置和脚本仍保留。"
}

disable_bot_service() {
  systemctl disable --now cf-ddns-bot.service 2>/dev/null || true
  systemctl daemon-reload
  echo "已停用 cf-ddns-bot.service；配置和脚本仍保留。"
}

print_menu() {
  clear 2>/dev/null || true
  echo "Cloudflare DDNS 交互管理"
  echo "配置文件：$ENV_FILE"
  echo "检测脚本：$WORKER"
  echo
  echo "1) 初始化/修改 Cloudflare 与 Telegram 配置"
  echo "2) 立即运行一次 DDNS 检测"
  echo "3) 安装/更新 systemd 定时器"
  echo "4) 查看状态与日志"
  echo "5) 测试 Telegram 推送"
  echo "6) 停用 systemd 定时器"
  echo "7) 立即调用换 IP API，并更新 DDNS"
  echo "8) 安装/更新 Telegram Bot 命令服务"
  echo "9) 停用 Telegram Bot 命令服务"
  echo "0) 退出"
  echo
}

main() {
  require_root
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"

  while true; do
    print_menu
    read -r -p "请选择操作: " choice || true

    case "$choice" in
      1) configure_env; pause ;;
      2) run_once; pause ;;
      3) install_timer; pause ;;
      4) show_status; pause ;;
      5) test_telegram; pause ;;
      6) disable_timer; pause ;;
      7) change_ip_once; pause ;;
      8) install_bot_service; pause ;;
      9) disable_bot_service; pause ;;
      0) exit 0 ;;
      *) echo "无效选择。"; sleep 1 ;;
    esac
  done
}

main "$@"
