#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
BIN_LINK="/usr/local/bin/ddns"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 用户执行安装：sudo ./install.sh"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 校验解码后的图片完整性：字节数 + 魔数 + 结尾标记。
# 截断的 PNG（缺少 IEND）会让 Telegram 报 IMAGE_PROCESS_FAILED。
verify_image() {
  local f="$1" bytes magic trailer
  bytes="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
  if [[ ! "$bytes" =~ ^[0-9]+$ || "$bytes" -lt 1000 ]]; then
    echo "图片资源不完整：$f 当前 ${bytes:-0} 字节，已停止安装。"
    exit 1
  fi
  case "$f" in
    *.png)
      magic="$(LC_ALL=C od -An -N8 -tx1 "$f" | tr -d ' \n')"
      trailer="$(LC_ALL=C tail -c 12 "$f" | od -An -tx1 | tr -d ' \n')"
      if [[ "$magic" != "89504e470d0a1a0a" || "$trailer" != "0000000049454e44ae426082" ]]; then
        echo "PNG 图片损坏（签名或 IEND 结尾不符）：$f，已停止安装。"
        exit 1
      fi
      ;;
    *.jpg|*.jpeg)
      magic="$(LC_ALL=C od -An -N2 -tx1 "$f" | tr -d ' \n')"
      trailer="$(LC_ALL=C tail -c 2 "$f" | od -An -tx1 | tr -d ' \n')"
      if [[ "$magic" != "ffd8" || "$trailer" != "ffd9" ]]; then
        echo "JPG 图片损坏（缺少 SOI/EOI 标记）：$f，已停止安装。"
        exit 1
      fi
      ;;
  esac
}

install -d -m 700 "$BASE_DIR"
install -m 700 "$SCRIPT_DIR/scripts/cf_ddns.sh" "$BASE_DIR/cf_ddns.sh"
install -m 700 "$SCRIPT_DIR/scripts/cf_change_ip.sh" "$BASE_DIR/cf_change_ip.sh"
install -m 700 "$SCRIPT_DIR/scripts/cf_ddns_bot.sh" "$BASE_DIR/cf_ddns_bot.sh"
install -m 700 "$SCRIPT_DIR/scripts/cf_ddns_manage.sh" "$BASE_DIR/cf_ddns_manage.sh"
if [[ -f "$SCRIPT_DIR/assets/panel_illustration.png.hex" ]]; then
  perl -0777 -ne 's/[^0-9A-Fa-f]//g; print pack("H*", $_)' "$SCRIPT_DIR/assets/panel_illustration.png.hex" > "$BASE_DIR/panel_illustration.png"
  verify_image "$BASE_DIR/panel_illustration.png"
  chmod 600 "$BASE_DIR/panel_illustration.png"
elif [[ -f "$SCRIPT_DIR/assets/panel_illustration.png" ]]; then
  install -m 600 "$SCRIPT_DIR/assets/panel_illustration.png" "$BASE_DIR/panel_illustration.png"
fi
if [[ -f "$SCRIPT_DIR/assets/panel_illustration.jpg.hex" ]]; then
  perl -0777 -ne 's/[^0-9A-Fa-f]//g; print pack("H*", $_)' "$SCRIPT_DIR/assets/panel_illustration.jpg.hex" > "$BASE_DIR/panel_illustration.jpg"
  verify_image "$BASE_DIR/panel_illustration.jpg"
  chmod 600 "$BASE_DIR/panel_illustration.jpg"
elif [[ -f "$SCRIPT_DIR/assets/panel_illustration.jpg" ]]; then
  install -m 600 "$SCRIPT_DIR/assets/panel_illustration.jpg" "$BASE_DIR/panel_illustration.jpg"
fi
ln -sf "$BASE_DIR/cf_ddns_manage.sh" "$BIN_LINK"
chmod 755 "$BIN_LINK"

echo "安装完成。"
echo "请执行：sudo ddns"
