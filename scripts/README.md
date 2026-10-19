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
