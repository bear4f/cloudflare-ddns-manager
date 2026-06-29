# Cloudflare DDNS Manager

适用于 Linux 服务器的 Cloudflare 动态 DNS 管理工具。提供带实时状态的交互式管理面板、systemd 定时任务、Cloudflare A/AAAA 记录自动更新（支持多条记录），以及一个图文并茂、可一键操作的 Telegram 控制面板。

---

## 目录

- [功能特性](#功能特性)
- [环境要求](#环境要求)
- [安装](#安装)
- [交互管理面板](#交互管理面板)
- [配置文件](#配置文件)
- [Boil 换 IP API](#boil-换-ip-api)
- [systemd 定时器](#systemd-定时器)
- [Telegram 通知与控制面板](#telegram-通知与控制面板)
- [日志](#日志)
- [更新与卸载](#更新与卸载)
- [安全建议](#安全建议)
- [常见问题](#常见问题)

---

## 功能特性

**DNS 更新**
- 自动获取公网 IP，支持 **IPv4（A）** 与 **IPv6（AAAA）**
- 公网 IP **多数据源容错**（ipify / icanhazip / ifconfig，任一可用即可）
- 一次更新**多条记录**（逗号或空格分隔）
- IP 未变化时不重复写入；记录不存在时自动创建
- 支持 Cloudflare proxied 小云朵开关与自定义 TTL

**交互管理面板（`ddns`）**
- 顶部**实时状态条**：定时器 / Bot 服务 / 当前记录（带颜色）
- 保存配置后**即时验证** Cloudflare Token、Zone 与每条记录
- 一键**实时跟随日志**、**在线更新**、**彻底卸载清理**

**Telegram 控制面板**
- 图文面板，按钮一键：换 IP、更新 DDNS、刷新、查看日志、启停定时器
- 逐条显示**「公网 IP ↔ DNS 记录」同步状态**：`✅` 已同步 / `⚠️` 待更新 / `❔` 未知
- HTML 富文本排版，操作进度在同一条消息内动态刷新
- 仅响应授权的 `TG_CHAT_ID`，其余一律忽略

**运维**
- 日志自动轮转（超过 2 MiB 仅保留最近 1000 行）
- 配置文件 600 权限保存，安装目录 700 权限
- 安装时校验图片素材完整性（PNG IEND、JPG SOI/EOI），避免损坏素材导致 Telegram 发图失败

---

## 环境要求

- Linux 服务器，推荐 Debian / Ubuntu
- systemd
- root 权限
- `curl`、`jq`、`flock`（缺失时安装脚本会自动安装）
- Cloudflare API Token

Cloudflare API Token 建议只授予目标 Zone，并至少包含：

- `Zone:Read`
- `DNS:Edit`

> 面板的同步状态展示依赖 `Zone:Read` + DNS 读取权限，`DNS:Edit` 已隐含读取能力。

---

## 安装

### Debian 一键在线安装（推荐）

适合没有 `git` 的 Debian / Ubuntu 服务器，复制整行执行：

```bash
apt-get update && apt-get install -y curl ca-certificates && \
curl -fsSL https://raw.githubusercontent.com/bear4f/cloudflare-ddns-manager/main/install-online.sh | bash
```

安装完成后执行：

```bash
ddns
```

> 若提示 raw 链接无法下载，请先确认仓库已设为 public。

### Git 安装

```bash
git clone https://github.com/bear4f/cloudflare-ddns-manager.git
cd cloudflare-ddns-manager
sudo ./install.sh
```

### 安装内容

| 路径 | 说明 |
| --- | --- |
| `/usr/local/ddns/cf_ddns.sh` | DDNS 检测与更新主脚本 |
| `/usr/local/ddns/cf_change_ip.sh` | 调用 Boil 换 IP API |
| `/usr/local/ddns/cf_ddns_bot.sh` | Telegram 命令 / 面板服务 |
| `/usr/local/ddns/cf_ddns_manage.sh` | 交互管理面板 |
| `/usr/local/ddns/panel_illustration.png` / `.jpg` | 面板配图 |
| `/usr/local/bin/ddns` | 指向管理面板的命令软链 |

---

## 交互管理面板

```bash
sudo ddns
```

面板顶部会显示实时状态条，菜单项：

| 选项 | 功能 |
| --- | --- |
| `1` | 初始化 / 修改 Cloudflare 与 Telegram 配置（保存后即时验证） |
| `2` | 立即运行一次 DDNS 检测 |
| `3` | 安装 / 更新 systemd 定时器 |
| `4` | 查看状态与日志 |
| `5` | 测试 Telegram 推送 |
| `6` | 停用 systemd 定时器 |
| `7` | 立即调用换 IP API 并更新 DDNS |
| `8` | 安装 / 更新 Telegram Bot 命令服务 |
| `9` | 停用 Telegram Bot 命令服务 |
| `l` | 实时跟随日志（`journalctl -f`） |
| `u` | 在线更新到最新版本 |
| `x` | 彻底卸载并清理 |
| `0` | 退出 |

**首次使用建议顺序：**

```text
1) 配置  →  2) 跑一次检测  →  3) 安装定时器
```

如需换 IP API 与 Telegram 命令，继续：

```text
7) 换 IP API + 更新 DDNS  →  8) 安装 Telegram Bot 命令服务
```

---

## 配置文件

配置保存在 `/usr/local/ddns/cf_ddns.env`（600 权限）：

```bash
CF_API_TOKEN='your_cloudflare_api_token'
ZONE_NAME='example.com'
RECORD_NAME='ddns.example.com'        # 多条记录用逗号或空格分隔：'a.example.com b.example.com'
RECORD_TYPE='A'                       # A=IPv4，AAAA=IPv6
TTL='120'                             # Cloudflare 自动 TTL 可填 1
PROXY='false'                         # DDNS 通常保持 false

IP_CHANGE_ENABLED='false'
IP_CHANGE_API_URL=''
IP_CHANGE_API_FORMAT_JSON='true'
IP_CHANGE_WAIT_SECONDS='8'

TG_ENABLED='false'
TG_BOT_TOKEN=''
TG_CHAT_ID=''
```

> 请勿把真实的 `cf_ddns.env` 上传到 GitHub。

---

## Boil 换 IP API

获得 Boil IP 面板的专属 API 后，在 `sudo ddns` 的配置项中启用换 IP API，填入专属链接：

```text
https://ippanel.boil.network/api/your-private-token
```

默认会自动追加 `format=json`；若链接已带查询参数，脚本会自动处理。

启用后流程（菜单 `7` 或 Telegram「🔁 换 IP」）：

1. 请求换 IP API
2. 等待 `IP_CHANGE_WAIT_SECONDS` 秒
3. 重新获取公网 IP
4. 更新 Cloudflare DNS 记录

> API 链接等同于密钥，请勿发到公开聊天、截图或仓库。

---

## systemd 定时器

在 `sudo ddns` 菜单选择 `3` 后生成：

- `/etc/systemd/system/cf-ddns.service`
- `/etc/systemd/system/cf-ddns.timer`

```bash
# 查看定时器
systemctl list-timers --all | grep cf-ddns

# 查看运行状态
systemctl status cf-ddns.timer --no-pager
systemctl status cf-ddns.service --no-pager
```

停用：`sudo ddns` → `6`，或在 Telegram 面板点「⏸️ 停用定时器」。

---

## Telegram 通知与控制面板

### 准备 Bot

1. 在 Telegram 搜索 `@BotFather`
2. 发送 `/newbot` 创建机器人，获得 **Bot Token**
3. 先给机器人发一条消息
4. 用 `getUpdates` 获取 **chat_id**（群组则先把机器人拉进群）
5. `sudo ddns` → `1` 启用 Telegram 并填写 Token / chat_id
6. （可选，用于 Telegram 内换 IP）启用并填写 Boil 换 IP API
7. `sudo ddns` → `8` 安装 Bot 命令服务（生成 `/etc/systemd/system/cf-ddns-bot.service`）

### 控制面板

发送 `/start` 或 `/panel` 打开图文控制面板。面板会逐条显示记录同步状态，按钮如下：

```text
🔁 换 IP        调用 Boil 换 IP API，然后自动更新 Cloudflare DDNS
📡 更新 DDNS    立即运行一次 DDNS 检测
🔄 刷新         刷新面板状态（公网 IP ↔ DNS 记录同步情况）
📜 日志         拉取最近 15 行运行日志
▶️/⏸️ 定时器   一键启用或停用 systemd 定时器
ℹ️ 帮助         查看可用命令
```

可用命令：

```text
/start    打开按钮控制面板
/panel    打开按钮控制面板
/changeip 调用换 IP API，然后自动更新 Cloudflare DDNS
/ddns     立即运行一次 DDNS 检测
/status   刷新当前公网 IP 与服务状态
/log      查看最近 15 行运行日志
/help     查看帮助
```

操作进度会在同一条面板消息内动态刷新，详细记录仍写入服务器日志。自动 DDNS 更新成功后也会推送一个新的面板。若图片发送失败，会自动退回文字面板并在日志记录原因。

**安全限制**

- Bot 只响应配置文件里的 `TG_CHAT_ID`，其余 Chat ID 一律忽略
- 「换 IP」「更新 DDNS」同一时间只允许一个任务运行（flock），避免重复触发

---

## 日志

```text
/var/log/cf_ddns.log
```

- 超过 2 MiB 自动轮转，仅保留最近 1000 行
- 可能包含真实域名、旧 / 新 IP，公开分享前请先脱敏
- 实时跟随：`sudo ddns` → `l`，或 `journalctl -fu cf-ddns-bot.service`

---

## 更新与卸载

**在线更新到最新版：** `sudo ddns` → `u`（或重新执行一键安装命令）。

**彻底卸载：** 最简单是 `sudo ddns` → `x`。也可手动执行：

```bash
sudo systemctl disable --now cf-ddns.timer 2>/dev/null || true
sudo systemctl disable --now cf-ddns-bot.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer
sudo rm -f /etc/systemd/system/cf-ddns-bot.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/ddns
sudo rm -rf /usr/local/ddns
sudo rm -f /var/log/cf_ddns.log
```

---

## 安全建议

- Cloudflare API Token 尽量限定到单个 Zone，仅授予 `Zone:Read` + `DNS:Edit`
- 不要公开 Boil 换 IP API 专属链接，它可触发你的服务器换 IP
- 不要上传真实的 `cf_ddns.env`
- 日志含敏感信息，分享前脱敏

---

## 常见问题

**Q：Telegram 面板图片发不出来，日志报 `IMAGE_PROCESS_FAILED`？**
A：通常是图片素材损坏（如 PNG 缺少 IEND 结尾）。本工具在安装时已校验素材完整性，并在发送失败时自动退回文字面板；重新执行一键安装即可拉取完整素材。

**Q：纯 IPv6 的服务器能用吗？**
A：可以。把 `RECORD_TYPE` 设为 `AAAA`，脚本会获取公网 IPv6 并更新 AAAA 记录。

**Q：可以同时更新多个域名吗？**
A：可以。`RECORD_NAME` 用逗号或空格分隔多条，例如 `a.example.com b.example.com`，它们需属于同一个 `ZONE_NAME`。

**Q：面板里记录显示 `⚠️ 待更新`？**
A：表示该记录在 Cloudflare 的值与当前公网 IP 不一致。点「📡 更新 DDNS」或等待定时器即可同步；显示 `❔` 则是暂时无法读取 Cloudflare（检查 Token 权限或网络）。
