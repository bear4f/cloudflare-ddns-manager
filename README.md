# Cloudflare DDNS Manager

一个适用于 Linux 服务器的 Cloudflare DDNS 脚本，提供交互式菜单、systemd 定时任务、Cloudflare A 记录自动更新，以及可选的 Telegram 变更通知。

## 功能

- 自动获取当前公网 IPv4
- 自动创建或更新 Cloudflare DNS A 记录
- IP 未变化时不重复更新
- 支持 Cloudflare proxied 小云朵开关
- 支持 systemd timer 定时运行
- 支持 Telegram 在记录创建或 IP 变化更新成功后推送通知
- 支持配置 Boil IP 面板专属换 IP API
- 支持 Telegram Bot 命令 `/changeip` 一键换 IP 并自动更新 DDNS
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

### Debian 一键在线安装

适合没有 `git` 的 Debian/Ubuntu 服务器。复制下面一整行执行：

```bash
apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/bear4f/cloudflare-ddns-manager/main/install-online.sh | bash
```

安装完成后执行：

```bash
ddns
```

如果提示 raw 链接无法下载，请先确认仓库已经设置为 public。

### Git 安装

如果服务器已安装 `git`，也可以使用：

```bash
git clone https://github.com/bear4f/cloudflare-ddns-manager.git
cd cloudflare-ddns-manager
sudo ./install.sh
```

安装后会创建：

- `/usr/local/ddns/cf_ddns.sh`
- `/usr/local/ddns/cf_change_ip.sh`
- `/usr/local/ddns/cf_ddns_bot.sh`
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
7. 立即调用换 IP API，并更新 DDNS
8. 安装或更新 Telegram Bot 命令服务
9. 停用 Telegram Bot 命令服务

首次使用建议按这个顺序操作：

```text
1) 初始化/修改 Cloudflare 与 Telegram 配置
2) 立即运行一次 DDNS 检测
3) 安装/更新 systemd 定时器
```

如果需要使用换 IP API 和 Telegram 命令，建议继续执行：

```text
7) 立即调用换 IP API，并更新 DDNS
8) 安装/更新 Telegram Bot 命令服务
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

IP_CHANGE_ENABLED='false'
IP_CHANGE_API_URL=''
IP_CHANGE_API_FORMAT_JSON='true'
IP_CHANGE_WAIT_SECONDS='8'

TG_ENABLED='false'
TG_BOT_TOKEN=''
TG_CHAT_ID=''
```

请不要把真实的 `cf_ddns.env` 上传到 GitHub。

## Boil 换 IP API

如果已获得 Boil IP 面板内测 API，可以在 `sudo ddns` 菜单的配置项中启用换 IP API，并填入面板生成的专属链接，例如：

```text
https://ippanel.boil.network/api/your-private-token
```

默认会自动在请求末尾追加 `format=json`：

```text
https://ippanel.boil.network/api/your-private-token?format=json
```

如果你的 API 链接已经包含 `format=json` 或其他查询参数，脚本会自动处理。API 链接通常等同于密钥，请不要发到公开聊天、截图或仓库。

配置完成后，可以在菜单中选择：

```text
7) 立即调用换 IP API，并更新 DDNS
```

流程是：

1. 请求换 IP API
2. 等待 `IP_CHANGE_WAIT_SECONDS` 秒
3. 重新获取公网 IP
4. 更新 Cloudflare DNS A 记录

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

## Telegram Bot 命令

如果想直接在 Telegram 中换 IP，需要在 `sudo ddns` 菜单中先完成：

1. 启用 Telegram 通知并填写 `TG_BOT_TOKEN`、`TG_CHAT_ID`
2. 启用并填写 Boil 换 IP API
3. 选择 `8) 安装/更新 Telegram Bot 命令服务`

安装后会创建：

- `/etc/systemd/system/cf-ddns-bot.service`

可用命令：

```text
/changeip - 调用换 IP API，然后自动更新 Cloudflare DDNS
/ddns - 只立即运行一次 DDNS 检测
/status - 查看当前公网 IP 和服务状态
/help - 查看帮助
```

安全限制：

- Bot 只响应配置文件里的 `TG_CHAT_ID`
- 其他 Chat ID 会被忽略
- `/changeip` 同一时间只允许一个任务运行，避免重复换 IP

查看 Bot 服务状态：

```bash
systemctl status cf-ddns-bot.service --no-pager
```

## 卸载

```bash
sudo systemctl disable --now cf-ddns.timer 2>/dev/null || true
sudo systemctl disable --now cf-ddns-bot.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer
sudo rm -f /etc/systemd/system/cf-ddns-bot.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/ddns
sudo rm -rf /usr/local/ddns
```

如需保留配置，请不要删除 `/usr/local/ddns/cf_ddns.env`。

## 安全提醒

- 不要把 Cloudflare API Token、Telegram Bot Token、真实域名配置提交到公开仓库
- 不要公开 Boil 换 IP API 专属链接，它可以触发你的服务器换 IP
- 推荐使用权限最小化的 Cloudflare API Token
- 如果仓库设为 public，请先确认 README、日志、截图、配置文件都没有敏感信息
