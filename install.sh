#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
BIN_LINK="/usr/local/bin/ddns"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 用户执行安装：sudo ./install.sh"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 700 "$BASE_DIR"
install -m 700 "$SCRIPT_DIR/scripts/cf_ddns.sh" "$BASE_DIR/cf_ddns.sh"
install -m 700 "$SCRIPT_DIR/scripts/cf_change_ip.sh" "$BASE_DIR/cf_change_ip.sh"
install -m 700 "$SCRIPT_DIR/scripts/cf_ddns_bot.sh" "$BASE_DIR/cf_ddns_bot.sh"
install -m 700 "$SCRIPT_DIR/scripts/cf_ddns_manage.sh" "$BASE_DIR/cf_ddns_manage.sh"
if [[ -f "$SCRIPT_DIR/assets/panel_illustration.jpg.hex" ]]; then
  perl -0777 -ne 's/[^0-9A-Fa-f]//g; print pack("H*", $_)' "$SCRIPT_DIR/assets/panel_illustration.jpg.hex" > "$BASE_DIR/panel_illustration.jpg"
  byte_count="$(wc -c < "$BASE_DIR/panel_illustration.jpg" | tr -d ' ')"
  if [[ "$byte_count" -lt 17000 ]]; then
    echo "图片资源不完整：$BASE_DIR/panel_illustration.jpg 当前 ${byte_count} 字节，已停止安装。"
    exit 1
  fi
  chmod 600 "$BASE_DIR/panel_illustration.jpg"
elif [[ -f "$SCRIPT_DIR/assets/panel_illustration.jpg" ]]; then
  install -m 600 "$SCRIPT_DIR/assets/panel_illustration.jpg" "$BASE_DIR/panel_illustration.jpg"
fi
rm -f "$BASE_DIR/panel_illustration.png"
ln -sf "$BASE_DIR/cf_ddns_manage.sh" "$BIN_LINK"
chmod 755 "$BIN_LINK"

echo "安装完成。"
echo "请执行：sudo ddns"
