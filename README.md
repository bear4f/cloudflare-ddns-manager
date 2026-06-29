# Cloudflare DDNS Manager

一个适用于 Linux 服务器的 Cloudflare DDNS 脚本，提供交互式菜单、systemd 定时任务、Cloudflare A 记录自动更新，以及可选的 Telegram 变更通知。

## 功能

- 自动获取当前公网 IPv4
- 自动创建或更新 Cloudflare DNS A 记录
- IP 未变化时不重复更新
- 支持 Cloudflare proxied 小云朵开关
- 支持 systemd timer 定时运行
- 支持 Telegram 在记录创建或 IP 变化更新成功后推送通知
- 配置文件使用 600 权限保存，避免密钥被普通用户读取

## 环境要求

- Linux 服务器，推荐 Debian 或 Ubuntu
- systemd
- root 权限
- `curl`、`jq`、`flock`
- Cloudflare API Token

Cloudflare API Token 建议只授予目标 Zone，并至少包含：

- `Zone:Read`
- `DNS:Edit`

## 安装

```bash
git clone https://github.com/bear4f/cloudflare-ddns-manager.git
cd cloudflare-ddns-manager
sudo ./install.sh
```

安装后会创建：

- `/usr/local/ddns/cf_ddns.sh`
- `/usr/local/ddns/cf_ddns_manage.sh`
- `/usr/local/bin/ddns`

## 使用

打开交互菜单：

```bash
sudo ddns
```

菜单包含：

1. 初始化或修改 Cloudflare 与 Telegram 配置
2. 立即运行一次 DDNS 检测
3. 安装或更新 systemd 定时器
4. 查看状态与日志
5. 测试 Telegram 推送
6. 停用 systemd 定时器

首次使用建议按这个顺序操作：

```text
1) 初始化/修改 Cloudflare 与 Telegram 配置
2) 立即运行一次 DDNS 检测
3) 安装/更新 systemd 定时器
```

## 配置文件

配置保存在：

```text
/usr/local/ddns/cf_ddns.env
```

示例字段：

```bash
CF_API_TOKEN='your_cloudflare_api_token'
ZONE_NAME='example.com'
RECORD_NAME='ddns.example.com'
TTL='120'
PROXY='false'

TG_ENABLED='false'
TG_BOT_TOKEN=''
TG_CHAT_ID=''
```

请不要把真实的 `cf_ddns.env` 上传到 GitHub。

## 日志

日志默认写入：

```text
/var/log/cf_ddns.log
```

日志可能包含真实域名、旧 IP、新 IP，公开分享前请先脱敏。

## systemd 定时器

在 `sudo ddns` 菜单中选择 `3` 后，脚本会生成：

- `/etc/systemd/system/cf-ddns.service`
- `/etc/systemd/system/cf-ddns.timer`

查看定时器：

```bash
systemctl list-timers --all | grep cf-ddns
```

查看运行状态：

```bash
systemctl status cf-ddns.timer --no-pager
systemctl status cf-ddns.service --no-pager
```

停用定时器：

```bash
sudo ddns
```

然后选择 `6`。

## Telegram 通知

如需 Telegram 通知：

1. 在 Telegram 搜索 `@BotFather`
2. 发送 `/newbot` 创建机器人并获得 Bot Token
3. 先给机器人发一条消息
4. 使用 Telegram `getUpdates` 获取 chat_id
5. 如用于群组通知，先把机器人拉进群
6. 在 `sudo ddns` 菜单中启用 Telegram 并填写配置

Telegram 只会在 DNS 记录创建或 IP 变化更新成功后推送。

## 卸载

```bash
sudo systemctl disable --now cf-ddns.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/ddns
sudo rm -rf /usr/local/ddns
```

如需保留配置，请不要删除 `/usr/local/ddns/cf_ddns.env`。

## 安全提醒

- 不要把 Cloudflare API Token、Telegram Bot Token、真实域名配置提交到公开仓库
- 推荐使用权限最小化的 Cloudflare API Token
- 如果仓库设为 public，请先确认 README、日志、截图、配置文件都没有敏感信息
