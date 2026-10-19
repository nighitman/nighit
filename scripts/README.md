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
