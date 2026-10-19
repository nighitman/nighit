# Telegram 通知 / Komari 探针监控脚本

通过 Telegram Bot API 主动推送消息，适合把探针状态、构建结果、磁盘/内存告警发到手机。

## 文件

| 文件 | 作用 |
|---|---|
| `telegram-notify.sh` | 发送文本（自动按 3900 字符分片）或文件到指定 chat |
| `komari-watch.sh` | 检查 agent 进程 / 面板连通性 / WebSocket / 磁盘 / 内存，**状态变化时才推送** |
| `telegram.env.example` | 凭据文件模板 |

## 配置凭据

```bash
mkdir -p ~/.config/komari
cp scripts/telegram.env.example ~/.config/komari/telegram.env
chmod 600 ~/.config/komari/telegram.env
# 编辑并填入 TELEGRAM_BOT_TOKEN 和 TELEGRAM_CHAT_ID
```

`chat_id` 获取方式：先给 bot 发一条 `/start`，然后：

```bash
. ~/.config/komari/telegram.env
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" \
  | python3 -c 'import sys,json; [print(u["message"]["chat"]["id"]) for u in json.load(sys.stdin)["result"] if "message" in u]'
```

## 使用

```bash
# 发文本
./scripts/telegram-notify.sh "hello from server"

# 静默发送（不响铃）
./scripts/telegram-notify.sh --silent "nightly job started"

# 发文件
./scripts/telegram-notify.sh --file ./report.txt --caption "build report"

# 探针巡检（健康时不发，状态变化时发）
./scripts/komari-watch.sh

# 强制发一条当前状态
./scripts/komari-watch.sh --force
```

`komari-watch.sh` 的退出码：`0` 健康、`1` 发现异常、`2` 推送失败。

## 命令 Bot（双向）

`telegram-bot.py` 用 long polling 接收消息并回复命令，只响应 `TELEGRAM_CHAT_ID` 对应的聊天，其他人发消息会被忽略。

```bash
# 处理一次积压消息后退出（调试用）
python3 scripts/telegram-bot.py --once

# 后台常驻
mkdir -p ~/.local/state/komari
setsid nohup python3 /workspace/scripts/telegram-bot.py \
  >> ~/.local/state/komari/bot.log 2>&1 < /dev/null &
echo $! > ~/.local/state/komari/bot.pid

# 停止
kill "$(cat ~/.local/state/komari/bot.pid)"
```

支持的命令：

| 命令 | 作用 |
|---|---|
| `/status` | agent 进程、面板连通性、WebSocket、磁盘、内存 |
| `/disk` | `/` 和 `/workspace` 占用 |
| `/mem` | 内存使用率 |
| `/ping` | 面板连通性和耗时 |
| `/log [n]` | 最近 n 行 agent 日志（默认 15，最多 60） |
| `/id` | 当前 chat_id |
| `/help` | 帮助 |

已读位置保存在 `~/.local/state/komari/bot.offset`，重启不会重复回复旧消息。

> 这是命令 bot，不接 LLM，所以不支持自由对话；未知文本会回复命令提示。

## 进程保活（看门狗）

`keepalive.sh` 每 60 秒检查 Komari agent 和 Telegram bot，发现掉线就自动拉起，并（限频）发 Telegram 通知。

```bash
# 检查一次
./scripts/keepalive.sh --once

# 后台常驻
setsid nohup /workspace/scripts/keepalive.sh >/dev/null 2>&1 < /dev/null &
echo $! > ~/.local/state/komari/keepalive.pid

# 查看日志
tail -f ~/.local/state/komari/keepalive.log
```

重启 agent 所需的端点/密钥放在 `~/.config/komari/agent.env`（`chmod 600`，不进仓库）：

```bash
KOMARI_ENDPOINT=https://komari.577591.xyz
KOMARI_AUTO_DISCOVERY_KEY=...
KOMARI_EXTRA_ARGS=--disable-web-ssh
```

**边界**：看门狗只能保证"容器存活期间"进程不掉；容器被回收、看门狗自身被杀，都无法自愈。它不是 systemd，也不能让 Cline 会话本身常驻。

## Argo 代理节点（Xray VLESS/WS + Cloudflare Quick Tunnel）

在无 root 的沙盒里运行 Xray 服务端，通过 Cloudflare Quick Tunnel 暴露，并自动生成 vless:// 链接和 base64 订阅。

```
Caddy (:10000) --/argo*--> Xray VLESS/WS (127.0.0.1:10001)
               --/sub.txt--> 订阅文件
        ^
        | cloudflared 命名隧道 / 临时隧道
https://cline.mailking.dpdns.org
```

| 文件 | 说明 |
|---|---|
| `scripts/argo-node.sh` | 启动/守护 Xray、Caddy、隧道；域名或链接变化时推送 Telegram |
| `~/.config/komari/argo/xray-server.json` | Xray 服务端配置（UUID 在里面，`chmod 600`；监听 10001） |
| `~/.config/komari/argo/Caddyfile` | 10000 端口分流：`/argo` → Xray，`/sub.txt` → 订阅文件 |
| `~/.local/state/komari/argo-sub/vless.txt` | 当前直连节点链接 |
| `~/.local/state/komari/argo-sub/sub.txt` | 当前 base64 订阅内容 |
| `~/.local/state/komari/argo-sub/url` | 当前订阅 URL |

查看/使用：

```bash
cat ~/.local/state/komari/argo-sub/url    # 订阅链接
cat ~/.local/state/komari/argo-sub/vless.txt  # 直连 vless:// 链接

./scripts/argo-node.sh --once   # 检查并重建
tail -f ~/.local/state/komari/argo.log
```

客户端（Xray 内核，如 v2rayN / NekoRay / Shadowrocket）直接添加订阅 URL，或导入 vless:// 链接。节点参数：`VLESS + TLS + WebSocket`，端口 `443`，路径 `/argo`，SNI/Host 为 `*.trycloudflare.com` 域名，`fp=chrome`。

### 命名隧道模式（固定域名）

如果存在 `~/.config/komari/argo/tunnel.token`，`argo-node.sh` 会优先使用 Cloudflare 命名隧道，不再创建 `trycloudflare.com` 临时域名：

```bash
# token 来自 Zero Trust -> Networks -> Tunnels -> Install connector
chmod 600 ~/.config/komari/argo/tunnel.token

cat > ~/.config/komari/argo/named.env <<'EOF'
NAMED_HOST=cline.mailking.dpdns.org
# 订阅与节点同域名，由 Caddy 分流 /sub.txt
NAMED_SUB_HOST=cline.mailking.dpdns.org
EOF
```

隧道只需要一个 Public Hostname：

| 域名 | 服务 |
|---|---|
| `cline.mailking.dpdns.org` | `http://127.0.0.1:10000`（Caddy） |

Caddy 再分流 `/argo*` → `127.0.0.1:10001`（Xray），`/sub.txt` → 订阅文件。

DNS 必须是 **Proxied CNAME** 指向 `<tunnel-id>.cfargotunnel.com`；如果指向源站 IP 会返回 522。

**限制与注意**：
- Quick Tunnel 域名在 cloudflared 重启后会变化，`argo-node.sh` 会自动重建订阅并通过 Telegram 推送新链接。
- 这是 Cloudflare 的临时隧道，适合测试/临时使用，不建议作为长期生产节点；长期稳定需要你自己的域名 + 命名隧道（`cloudflared tunnel create` + DNS 路由），或直接部署到 VPS。
- 带宽、连接数受沙盒和 Quick Tunnel 限制；容器回收后节点失效。
- UUID 就是节点密码，不要提交到公开仓库；泄露后删除 `xray-server.json` 和 `uuid` 重新运行即可轮换。

## SSH 访问（无 root 用户态方案）


沙盒里没有 `sshd` 也没有 `sudo`，因此用 `asyncssh` 起一个**用户态 SSH 服务端**，再通过 `bore.pub` 反向隧道暴露：

| 组件 | 作用 |
|---|---|
| `ssh-server.py` | 监听 `127.0.0.1:2222`，仅公钥认证，登录用户 `node`，支持 PTY shell / exec / SFTP / SCP |
| `ssh-tunnel.sh` | 守护 SSH 服务端和 bore 隧道；隧道重启后端口会变，自动推送新命令到 Telegram |
| `~/.config/komari/ssh_client_ed25519_key` | 客户端私钥（已通过 Telegram 发送一次） |
| `~/.local/state/komari/ssh-port` | 当前公网端口 |

客户端使用：

```bash
# 把 Telegram 收到的私钥保存为 ~/komari_sandbox_key
chmod 600 ~/komari_sandbox_key

# 连接（端口以 Telegram 最新消息 / ssh-port 文件为准）
ssh -p <port> -i ~/komari_sandbox_key \
  -o StrictHostKeyChecking=accept-new node@bore.pub

# 传文件
scp -P <port> -i ~/komari_sandbox_key ./file node@bore.pub:/workspace/
```

换成你自己的公钥（推荐）：

```bash
cat ~/.ssh/id_ed25519.pub >> ~/.config/komari/ssh_authorized_keys
# 下次认证立即生效，无需重启
```

管理：

```bash
./scripts/ssh-tunnel.sh --once        # 启动/检查一次
setsid nohup ./scripts/ssh-tunnel.sh >/dev/null 2>&1 < /dev/null &
kill "$(cat ~/.local/state/komari/ssh-tunnel.pid)"
tail -f ~/.local/state/komari/ssh-tunnel.log
```

**安全与限制**：
- 仅公钥认证，没有密码登录；但**任何拿到私钥和端口的人都能登录**，泄露后请删除 `ssh_authorized_keys` 中的对应公钥并换 key。
- 走第三方中继 `bore.pub`；SSH 本身端到端加密，中继看不到内容，但能看到连接元数据。
- 端口每次隧道重启都会变化（固定端口在 bore.pub 上外网不可达），以 Telegram 推送为准。
- 权限是普通用户 `node`，不是 root；容器被回收后 SSH 也会一并消失。

## 定时执行




crontab（每分钟巡检一次，仅在状态变化时发消息）：

```cron
* * * * * /path/to/scripts/komari-watch.sh >/dev/null 2>&1
```

没有 cron 的环境可以用 `nohup` 循环：

```bash
nohup bash -c 'while true; do /path/to/scripts/komari-watch.sh; sleep 60; done' \
  > ~/.local/state/komari/watch.log 2>&1 &
```

## 构建结果接入

```bash
if npm test; then
  ./scripts/telegram-notify.sh "✅ 构建通过: $(date '+%F %T')"
else
  ./scripts/telegram-notify.sh "❌ 构建失败: $(date '+%F %T')"
fi
```

## 安全注意

- `telegram.env` 权限保持 `600`，已在 `.gitignore` 中排除 `*.env` / `*.log` / `*.pid`。
- Token 泄露后可在 BotFather 中 `/revoke` 重置。
- 沙盒/容器被销毁后脚本进程不会保留；长期监控请部署到长期运行的服务器。
