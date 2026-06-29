#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
BIN_LINK="/usr/local/bin/ddns"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/bear4f/cloudflare-ddns-manager/main}"

if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  echo "请使用 root 用户执行安装。"
  exit 1
fi

install_deps() {
  local missing=()
  local cmd=""

  for cmd in curl jq flock perl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl jq util-linux perl-base ca-certificates
  else
    echo "缺少依赖：${missing[*]}"
    echo "请先安装：curl jq util-linux perl-base ca-certificates"
    exit 1
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  local sep="?"

  [[ "$url" == *\?* ]] && sep="&"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "${url}${sep}v=$(date +%s)" -o "$output"
}

install_remote_script() {
  local remote_path="$1"
  local target_path="$2"
  local tmp_file="$3"

  echo "拉取：${remote_path}"
  download_file "${RAW_BASE}/${remote_path}" "$tmp_file"
  bash -n "$tmp_file"
  install -m 700 "$tmp_file" "$target_path"
}

install_remote_asset() {
  local remote_path="$1"
  local target_path="$2"
  local tmp_file="$3"
  local byte_count=""

  echo "拉取：${remote_path}"
  download_file "${RAW_BASE}/${remote_path}" "$tmp_file"
  perl -0777 -ne 's/[^0-9A-Fa-f]//g; print pack("H*", $_)' "$tmp_file" > "$target_path"
  byte_count="$(wc -c < "$target_path" | tr -d ' ')"
  if [[ "$target_path" == *.jpg && "$byte_count" -lt 1000 ]]; then
    echo "图片资源不完整：${target_path} 当前 ${byte_count} 字节，已停止安装。"
    exit 1
  fi
  chmod 600 "$target_path"
}

main() {
  install_deps

  local tmp_dir=""
  tmp_dir="$(mktemp -d)"
  trap '[[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"' EXIT

  install -d -m 700 "$BASE_DIR"

  install_remote_script "scripts/cf_ddns.sh" "$BASE_DIR/cf_ddns.sh" "$tmp_dir/cf_ddns.sh"
  install_remote_script "scripts/cf_change_ip.sh" "$BASE_DIR/cf_change_ip.sh" "$tmp_dir/cf_change_ip.sh"
  install_remote_script "scripts/cf_ddns_bot.sh" "$BASE_DIR/cf_ddns_bot.sh" "$tmp_dir/cf_ddns_bot.sh"
  install_remote_script "scripts/cf_ddns_manage.sh" "$BASE_DIR/cf_ddns_manage.sh" "$tmp_dir/cf_ddns_manage.sh"
  install_remote_asset "assets/panel_illustration.jpg.hex" "$BASE_DIR/panel_illustration.jpg" "$tmp_dir/panel_illustration.jpg.hex"
  rm -f "$BASE_DIR/panel_illustration.png"

  ln -sf "$BASE_DIR/cf_ddns_manage.sh" "$BIN_LINK"
  chmod 755 "$BIN_LINK"

  echo
  echo "安装完成。"
  echo "现在执行：ddns"
}

main "$@"
