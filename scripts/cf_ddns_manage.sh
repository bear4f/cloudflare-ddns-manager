#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
WORKER="$BASE_DIR/cf_ddns.sh"
CHANGER="$BASE_DIR/cf_change_ip.sh"
BOT_WORKER="$BASE_DIR/cf_ddns_bot.sh"
LOG_FILE="/var/log/cf_ddns.log"
BIN_LINK="/usr/local/bin/ddns"
SERVICE_FILE="/etc/systemd/system/cf-ddns.service"
TIMER_FILE="/etc/systemd/system/cf-ddns.timer"
BOT_SERVICE_FILE="/etc/systemd/system/cf-ddns-bot.service"
CF_API_BASE="https://api.cloudflare.com/client/v4"
INSTALL_URL="https://raw.githubusercontent.com/bear4f/cloudflare-ddns-manager/main/install-online.sh"

# 颜色（仅在交互终端启用）。
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""
fi

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
  RECORD_TYPE="A"
  TTL="120"
  PROXY="false"
  TG_ENABLED="false"
  TG_BOT_TOKEN=""
  TG_CHAT_ID=""
  GEO_ENABLED="true"
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

prompt_record_type_keep() {
  local old="${RECORD_TYPE:-A}"
  local input=""

  while true; do
    read -r -p "请输入记录类型：A=IPv4，AAAA=IPv6 [$old]: " input || true
    input="${input:-$old}"
    input="${input^^}"
    case "$input" in
      A|AAAA)
        RECORD_TYPE="$input"
        return 0
        ;;
      *)
        echo "请输入 A 或 AAAA。"
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
#
# RECORD_NAME 支持多条记录，用逗号或空格分隔，例如：
# RECORD_NAME='a.example.com b.example.com'
# RECORD_TYPE=A 更新 IPv4；RECORD_TYPE=AAAA 更新 IPv6。
COMMENT_EOF

    printf 'CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
    printf 'ZONE_NAME=%q\n' "$ZONE_NAME"
    printf 'RECORD_NAME=%q\n' "$RECORD_NAME"
    printf 'RECORD_TYPE=%q\n' "$RECORD_TYPE"
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

    echo
    cat <<'COMMENT_EOF'
# 面板显示选项
# GEO_ENABLED=true 时，Telegram 面板会显示公网 IP 的地区 / ISP 归属。
# 该功能会把本机公网 IP 发送给第三方地理库（ip-api.com / ipwho.is）查询。
COMMENT_EOF

    printf 'GEO_ENABLED=%q\n' "$GEO_ENABLED"
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

# 保存后立即验证 Cloudflare Token / Zone / 记录，尽早暴露配置错误。
verify_cloudflare() {
  command -v jq >/dev/null 2>&1 || return 0
  [[ -n "${CF_API_TOKEN:-}" && -n "${ZONE_NAME:-}" ]] || return 0

  echo
  echo "正在验证 Cloudflare 配置..."

  local resp status
  resp="$(curl -fsS --connect-timeout 8 --max-time 20 \
    "$CF_API_BASE/user/tokens/verify" \
    -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
  status="$(printf '%s' "$resp" | jq -r '.result.status // empty' 2>/dev/null || true)"
  if [[ "$status" == "active" ]]; then
    echo "  ${C_GREEN}✓${C_RESET} API Token 有效。"
  else
    echo "  ${C_RED}✗${C_RESET} API Token 验证未通过：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null || echo '无法连接')"
    return 1
  fi

  local zone_resp zone_id
  zone_resp="$(curl -fsS --connect-timeout 8 --max-time 20 \
    "$CF_API_BASE/zones?name=$(jq -rn --arg v "$ZONE_NAME" '$v|@uri')&status=active" \
    -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
  zone_id="$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  if [[ -z "$zone_id" ]]; then
    echo "  ${C_RED}✗${C_RESET} 未找到 Zone：$ZONE_NAME（请确认域名与 Token 权限）。"
    return 1
  fi
  echo "  ${C_GREEN}✓${C_RESET} Zone 已找到：$ZONE_NAME"

  local rtype="${RECORD_TYPE:-A}" name rec_resp content
  local raw="${RECORD_NAME// /,}"
  IFS=',' read -r -a _recs <<<"$raw"
  for name in "${_recs[@]}"; do
    [[ -n "$name" ]] || continue
    rec_resp="$(curl -fsS --connect-timeout 8 --max-time 20 \
      "$CF_API_BASE/zones/${zone_id}/dns_records?type=${rtype}&name=$(jq -rn --arg v "$name" '$v|@uri')" \
      -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
    content="$(printf '%s' "$rec_resp" | jq -r '.result[0].content // empty' 2>/dev/null || true)"
    if [[ -n "$content" ]]; then
      echo "  ${C_GREEN}✓${C_RESET} ${rtype} 记录 ${name} 当前值：${content}"
    else
      echo "  ${C_YELLOW}!${C_RESET} ${rtype} 记录 ${name} 尚不存在，首次运行将自动创建。"
    fi
  done
}

configure_env() {
  load_env

  echo
  echo "=== Cloudflare DDNS 配置 ==="
  echo "说明：下面不会回显已保存的真实域名、记录名或密钥。"
  echo

  prompt_secret_keep CF_API_TOKEN "请输入 Cloudflare API Token"
  prompt_sensitive_text_keep ZONE_NAME "请输入 Cloudflare Zone Name" "example.com"
  prompt_sensitive_text_keep RECORD_NAME "请输入需 DDNS 更新的完整记录域名（多条用逗号/空格分隔）" "ddns.example.com"
  prompt_record_type_keep
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
    prompt_bool_keep GEO_ENABLED "是否在面板显示 IP 地区/ISP 归属？（会向第三方查询本机公网 IP）" "${GEO_ENABLED:-true}"
  else
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
  fi

  save_env
  verify_cloudflare || echo "${C_YELLOW}提示：Cloudflare 验证未完全通过，可重新选择 1 修改配置。${C_RESET}"
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
# 用按钟点的 OnCalendar，每 ${minutes} 分钟整必定触发；不依赖服务上次激活时间，
# 运行中重装定时器后也会在下一个时间点照常触发（避免 OnUnitActiveSec 失去锚点而不再运行）。
OnCalendar=*:0/${minutes}
OnBootSec=30s
AccuracySec=1s
Persistent=true
Unit=cf-ddns.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable cf-ddns.timer
  systemctl restart cf-ddns.timer

  # 安装后立即同步一次：既给用户即时反馈，也确保服务有一条运行记录。
  echo "立即运行一次 DDNS 检测..."
  systemctl start cf-ddns.service || bash "$WORKER" || true

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
  echo "可用命令：/changeip /ddns /status /log /help"
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

follow_log() {
  if command -v journalctl >/dev/null 2>&1; then
    echo "实时跟随 Bot 服务日志，按 Ctrl+C 退出。"
    journalctl -fu cf-ddns-bot.service --no-pager || true
  elif [[ -f "$LOG_FILE" ]]; then
    echo "实时跟随 $LOG_FILE，按 Ctrl+C 退出。"
    tail -f "$LOG_FILE" || true
  else
    echo "暂无可跟随的日志。"
  fi
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

update_self() {
  echo "将从 GitHub 拉取最新版本并覆盖安装："
  echo "  $INSTALL_URL"
  read -r -p "确认更新？[y/N]: " ans || true
  case "${ans,,}" in
    y|yes)
      if curl -fsSL "${INSTALL_URL}?v=$(date +%s)" | bash; then
        echo "更新完成。请重新执行 ddns 进入最新菜单。"
        exit 0
      else
        echo "更新失败，请检查网络或稍后重试。"
        return 1
      fi
      ;;
    *)
      echo "已取消更新。"
      ;;
  esac
}

uninstall_all() {
  echo "${C_RED}${C_BOLD}警告：这将彻底卸载并清理以下内容：${C_RESET}"
  echo "  - systemd 单元：cf-ddns.timer / cf-ddns.service / cf-ddns-bot.service"
  echo "  - 目录：$BASE_DIR（含配置与密钥）"
  echo "  - 命令软链：$BIN_LINK"
  echo "  - 日志：$LOG_FILE"
  read -r -p "请输入大写 YES 确认卸载: " ans || true
  if [[ "$ans" != "YES" ]]; then
    echo "已取消卸载。"
    return 0
  fi

  systemctl disable --now cf-ddns.timer 2>/dev/null || true
  systemctl disable --now cf-ddns-bot.service 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE" "$BOT_SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true
  rm -f "$BIN_LINK"
  rm -f "$LOG_FILE"
  rm -rf "$BASE_DIR"

  echo "${C_GREEN}已完成卸载与清理。${C_RESET}"
  exit 0
}

status_summary() {
  local timer bot dns_state

  timer="$(systemctl is-active cf-ddns.timer 2>/dev/null || echo inactive)"
  bot="$(systemctl is-active cf-ddns-bot.service 2>/dev/null || echo inactive)"

  local timer_disp bot_disp
  if [[ "$timer" == "active" ]]; then timer_disp="${C_GREEN}● 定时器 active${C_RESET}"; else timer_disp="${C_RED}○ 定时器 ${timer}${C_RESET}"; fi
  if [[ "$bot" == "active" ]]; then bot_disp="${C_GREEN}● Bot active${C_RESET}"; else bot_disp="${C_RED}○ Bot ${bot}${C_RESET}"; fi

  load_env
  local record_disp
  if [[ -n "${RECORD_NAME:-}" ]]; then
    record_disp="${C_CYAN}${RECORD_TYPE:-A} ${RECORD_NAME}${C_RESET}"
  else
    record_disp="${C_YELLOW}未配置记录${C_RESET}"
  fi

  printf '  %s   %s\n' "$timer_disp" "$bot_disp"
  printf '  记录：%s\n' "$record_disp"
}

print_menu() {
  clear 2>/dev/null || true
  echo "${C_BOLD}${C_CYAN}╔══════════════════════════════════════╗${C_RESET}"
  echo "${C_BOLD}${C_CYAN}║      Cloudflare DDNS 交互管理面板     ║${C_RESET}"
  echo "${C_BOLD}${C_CYAN}╚══════════════════════════════════════╝${C_RESET}"
  status_summary
  echo "${C_DIM}  配置：$ENV_FILE${C_RESET}"
  echo
  echo "  ${C_BOLD}1)${C_RESET} 初始化/修改 Cloudflare 与 Telegram 配置"
  echo "  ${C_BOLD}2)${C_RESET} 立即运行一次 DDNS 检测"
  echo "  ${C_BOLD}3)${C_RESET} 安装/更新 systemd 定时器"
  echo "  ${C_BOLD}4)${C_RESET} 查看状态与日志"
  echo "  ${C_BOLD}5)${C_RESET} 测试 Telegram 推送"
  echo "  ${C_BOLD}6)${C_RESET} 停用 systemd 定时器"
  echo "  ${C_BOLD}7)${C_RESET} 立即调用换 IP API 并更新 DDNS"
  echo "  ${C_BOLD}8)${C_RESET} 安装/更新 Telegram Bot 命令服务"
  echo "  ${C_BOLD}9)${C_RESET} 停用 Telegram Bot 命令服务"
  echo "  ${C_BOLD}l)${C_RESET} 实时跟随日志"
  echo "  ${C_BOLD}u)${C_RESET} 更新到最新版本"
  echo "  ${C_BOLD}x)${C_RESET} ${C_RED}彻底卸载并清理${C_RESET}"
  echo "  ${C_BOLD}0)${C_RESET} 退出"
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
      l|L) follow_log; pause ;;
      u|U) update_self; pause ;;
      x|X) uninstall_all; pause ;;
      0) exit 0 ;;
      *) echo "无效选择。"; sleep 1 ;;
    esac
  done
}

main "$@"
