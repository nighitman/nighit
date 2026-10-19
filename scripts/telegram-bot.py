#!/usr/bin/env python3
"""Telegram command bot for the Komari sandbox.

Long-polls the Telegram Bot API and replies to a small set of commands.
Only the chat id configured as TELEGRAM_CHAT_ID is served.

Usage:
    python3 telegram-bot.py --once    # process pending updates, then exit
    python3 telegram-bot.py           # run forever (long polling)

Credentials (default: ~/.config/komari/telegram.env):
    TELEGRAM_BOT_TOKEN=...
    TELEGRAM_CHAT_ID=...
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from pathlib import Path

ENV_FILE = Path(os.environ.get("TELEGRAM_ENV_FILE", Path.home() / ".config/komari/telegram.env"))
KOMARI_DIR = Path(os.environ.get("KOMARI_DIR", Path.home() / ".local/share/komari"))
AGENT_PID_FILE = KOMARI_DIR / "agent.pid"
AGENT_LOG = KOMARI_DIR / "agent.log"
ENDPOINT = os.environ.get("KOMARI_ENDPOINT", "https://komari.577591.xyz")
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "komari"
OFFSET_FILE = STATE_DIR / "bot.offset"

MAX_MESSAGE = 3900
STOP = False


def log(message: str) -> None:
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}", flush=True)


def load_env() -> tuple[str, str]:
    values: dict[str, str] = {}
    if ENV_FILE.exists():
        for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            key, _, value = raw.partition("=")
            values[key.strip()] = value.strip().strip("'\"")
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or values.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID") or values.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        raise SystemExit(f"TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID missing in {ENV_FILE}")
    return token, chat_id


TOKEN, CHAT_ID = load_env()
API = f"https://api.telegram.org/bot{TOKEN}"
ALLOWED = {str(CHAT_ID)}


def api(method: str, payload: dict | None = None, timeout: int = 40) -> dict:
    data = urllib.parse.urlencode(payload).encode() if payload else None
    request = urllib.request.Request(f"{API}/{method}", data=data)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def send(text: str, reply_to: int | None = None) -> None:
    chunks = [text[i:i + MAX_MESSAGE] for i in range(0, len(text), MAX_MESSAGE)] or [""]
    for index, chunk in enumerate(chunks):
        payload = {
            "chat_id": CHAT_ID,
            "text": chunk,
            "disable_web_page_preview": "true",
        }
        if reply_to and index == 0:
            payload["reply_to_message_id"] = str(reply_to)
        try:
            api("sendMessage", payload)
        except urllib.error.HTTPError as exc:
            log(f"sendMessage failed: {exc.code} {exc.read().decode('utf-8', 'replace')[:300]}")


def human_bytes(num: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(num) < 1024 or unit == "TiB":
            return f"{num:.1f} {unit}"
        num /= 1024
    return f"{num:.1f} TiB"


def agent_pid() -> int | None:
    try:
        pid = int(re.sub(r"\D", "", AGENT_PID_FILE.read_text()))
        os.kill(pid, 0)
        return pid
    except Exception:
        pass
    try:
        output = subprocess.run(
            ["pgrep", "-f", r"komari-agent|(^|/)agent -e "],
            capture_output=True, text=True, timeout=5,
        ).stdout.split()
        return int(output[0]) if output else None
    except Exception:
        return None


def process_uptime(pid: int) -> str:
    try:
        output = subprocess.run(
            ["ps", "-o", "etime=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        return output or "unknown"
    except Exception:
        return "unknown"


def endpoint_status() -> str:
    try:
        request = urllib.request.Request(ENDPOINT, method="GET")
        with urllib.request.urlopen(request, timeout=10) as response:
            return f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        return f"HTTP {exc.code}"
    except Exception as exc:
        return f"unreachable ({type(exc).__name__})"


def last_websocket_state() -> str:
    try:
        with AGENT_LOG.open("r", encoding="utf-8", errors="replace") as handle:
            lines = deque(handle, maxlen=400)
    except FileNotFoundError:
        return "log missing"
    for line in reversed(lines):
        if "WebSocket connected" in line:
            return "connected (v2)" if "v2" in line else "connected"
        if "WebSocket disconnected" in line:
            return "disconnected"
    return "unknown"


def disk_line(path: str) -> str:
    try:
        usage = shutil.disk_usage(path)
    except Exception:
        return f"{path}: n/a"
    percent = usage.used * 100 / usage.total if usage.total else 0
    return f"{path}: {percent:.0f}% used ({human_bytes(usage.used)}/{human_bytes(usage.total)})"


def mem_line() -> str:
    info: dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, _, rest = line.partition(":")
            info[key] = int(rest.strip().split()[0])
    except Exception:
        return "memory: n/a"
    total = info.get("MemTotal", 0) * 1024
    available = info.get("MemAvailable", 0) * 1024
    used = total - available
    percent = used * 100 / total if total else 0
    return f"memory: {percent:.0f}% used ({human_bytes(used)}/{human_bytes(total)})"


def status_text() -> str:
    pid = agent_pid()
    lines = [
        "📊 Komari 节点状态",
        f"主机: {socket.gethostname()}",
        f"时间: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}",
        f"面板: {ENDPOINT} ({endpoint_status()})",
        f"agent: {'running, PID ' + str(pid) if pid else 'NOT RUNNING'}",
    ]
    if pid:
        lines.append(f"运行时长: {process_uptime(pid)}")
    lines.append(f"WebSocket: {last_websocket_state()}")
    lines.append(disk_line("/workspace"))
    lines.append(mem_line())
    return "\n".join(lines)


def log_text(argument: str) -> str:
    try:
        count = int(argument) if argument else 15
    except ValueError:
        count = 15
    count = max(1, min(count, 60))
    try:
        with AGENT_LOG.open("r", encoding="utf-8", errors="replace") as handle:
            lines = list(deque(handle, maxlen=count))
    except FileNotFoundError:
        return f"日志不存在: {AGENT_LOG}"
    return f"📜 {AGENT_LOG.name} (last {len(lines)} lines)\n" + "".join(lines)


HELP_TEXT = """🤖 Komari 命令 bot

/status  节点状态（agent/面板/WebSocket/磁盘/内存）
/disk    磁盘占用
/mem     内存占用
/ping    连通性测试
/log [n] 最近 n 行 agent 日志（默认 15，最多 60）
/id      当前 chat_id
/help    显示本帮助

说明：这是命令 bot，不接 LLM，暂不支持自由对话。"""


def handle_command(text: str) -> str:
    text = text.strip()
    command, _, argument = text.partition(" ")
    command = command.split("@", 1)[0].lower()
    argument = argument.strip()

    if command in ("/start", "/help"):
        return HELP_TEXT
    if command == "/status":
        return status_text()
    if command == "/disk":
        return "💾 磁盘\n" + "\n".join(disk_line(path) for path in ("/", "/workspace"))
    if command == "/mem":
        return "🧠 " + mem_line()
    if command == "/ping":
        started = time.time()
        state = endpoint_status()
        return f"🏓 pong\n面板: {ENDPOINT} ({state})\n耗时: {(time.time() - started) * 1000:.0f} ms"
    if command == "/log":
        return log_text(argument)
    if command == "/id":
        return f"chat_id: {CHAT_ID}"
    return "暂不支持自由对话。发送 /help 查看可用命令。"


def read_offset() -> int | None:
    try:
        return int(OFFSET_FILE.read_text().strip())
    except Exception:
        return None


def save_offset(offset: int) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    OFFSET_FILE.write_text(str(offset))


def process_update(update: dict) -> None:
    message = update.get("message") or update.get("edited_message") or {}
    chat = message.get("chat", {})
    chat_id = str(chat.get("id", ""))
    text = message.get("text", "")
    if not text:
        return
    if chat_id not in ALLOWED:
        log(f"ignored message from unauthorized chat_id={chat_id}")
        return
    log(f"command from {chat.get('username') or chat_id}: {text!r}")
    send(handle_command(text), reply_to=message.get("message_id"))


def poll_once(timeout: int) -> int:
    offset = read_offset()
    payload: dict[str, str] = {"timeout": str(timeout), "allowed_updates": '["message"]'}
    if offset is not None:
        payload["offset"] = str(offset)
    try:
        response = api("getUpdates", payload, timeout=timeout + 15)
    except Exception as exc:
        log(f"getUpdates failed: {exc}")
        return 0

    updates = response.get("result", [])
    for update in updates:
        process_update(update)
        save_offset(int(update["update_id"]) + 1)
    return len(updates)


def stop_handler(_signum, _frame) -> None:
    global STOP
    STOP = True


def main() -> None:
    once = "--once" in sys.argv[1:]
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    log(f"bot started (once={once}, chat_id={CHAT_ID})")

    if once:
        processed = poll_once(0)
        log(f"processed {processed} update(s), exiting")
        return

    while not STOP:
        processed = poll_once(25)
        if not processed:
            time.sleep(2)
    log("bot stopped")


if __name__ == "__main__":
    main()



