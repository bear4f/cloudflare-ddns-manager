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
if [[ -f "$SCRIPT_DIR/assets/panel_illustration.jpg.b64" ]]; then
  tr -cd 'A-Za-z0-9+/=' < "$SCRIPT_DIR/assets/panel_illustration.jpg.b64" | base64 -d > "$BASE_DIR/panel_illustration.jpg"
  chmod 600 "$BASE_DIR/panel_illustration.jpg"
elif [[ -f "$SCRIPT_DIR/assets/panel_illustration.png.b64" ]]; then
  tr -cd 'A-Za-z0-9+/=' < "$SCRIPT_DIR/assets/panel_illustration.png.b64" | base64 -d > "$BASE_DIR/panel_illustration.png"
  chmod 600 "$BASE_DIR/panel_illustration.png"
fi
ln -sf "$BASE_DIR/cf_ddns_manage.sh" "$BIN_LINK"
chmod 755 "$BIN_LINK"

echo "安装完成。"
echo "请执行：sudo ddns"
