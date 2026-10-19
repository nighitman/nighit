#!/usr/bin/env bash
# ssh-tunnel.sh - keep the user-space SSH server and its bore.pub tunnel alive.
#
# Exposes 127.0.0.1:2222 (scripts/ssh-server.py) as bore.pub:<random-port>.
# The port changes whenever the tunnel restarts; the latest command is written
# to ~/.local/state/komari/ssh-port and pushed to Telegram.
#
# Usage:
#   ./ssh-tunnel.sh --once
#   ./ssh-tunnel.sh                 # loop, default interval 15s
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_SCRIPT="${SERVER_SCRIPT:-$SCRIPT_DIR/ssh-server.py}"
BORE="${BORE:-$HOME/.local/bin/bore}"
NOTIFY="${TELEGRAM_NOTIFY:-$SCRIPT_DIR/telegram-notify.sh}"
KEY="${SSH_CLIENT_KEY:-$HOME/.config/komari/ssh_client_ed25519_key}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/komari"
LOG_FILE="$STATE_DIR/ssh-tunnel.log"
PORT_FILE="$STATE_DIR/ssh-port"
SERVER_LOG="$STATE_DIR/ssh-server.log"
BORE_LOG="$STATE_DIR/bore.log"
KEY_SENT_MARKER="$STATE_DIR/ssh-key-sent"
INTERVAL=15
ONCE=false
SEND_NOTIFY=true

while [ $# -gt 0 ]; do
    case "$1" in
        --once) ONCE=true; shift ;;
        --interval) INTERVAL="${2:?}"; shift 2 ;;
        --no-notify) SEND_NOTIFY=false; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

notify() {
    [ "$SEND_NOTIFY" = true ] || return 0
    [ -x "$NOTIFY" ] || return 0
    "$NOTIFY" --silent "$1" >/dev/null 2>&1 || true
}

server_pid() {
    pgrep -f '^python3 /workspace/scripts/ssh-server\.py$' 2>/dev/null | head -n 1
}

tunnel_pid() {
    pgrep -f "^${BORE} local 2222 --to bore\.pub$" 2>/dev/null | head -n 1
}

start_server() {
    if [ -n "$(server_pid)" ]; then
        return 0
    fi
    setsid nohup python3 "$SERVER_SCRIPT" >> "$SERVER_LOG" 2>&1 < /dev/null &
    sleep 2
    local pid
    pid="$(server_pid)"
    if [ -z "$pid" ]; then
        log "ssh server failed to start (see $SERVER_LOG)"
        return 1
    fi
    log "ssh server started (PID $pid)"
}

send_key_once() {
    [ "$SEND_NOTIFY" = true ] || return 0
    [ -r "$KEY" ] || return 0
    [ -f "$KEY_SENT_MARKER" ] && return 0
    if "$NOTIFY" --file "$KEY" \
        --caption "SSH 私钥：保存为 ~/komari_sandbox_key 后执行 chmod 600 ~/komari_sandbox_key" \
        >/dev/null 2>&1; then
        touch "$KEY_SENT_MARKER"
        log "private key sent to Telegram"
    fi
}

start_tunnel() {
    if [ -n "$(tunnel_pid)" ]; then
        return 0
    fi
    if [ ! -x "$BORE" ]; then
        log "bore binary missing: $BORE"
        return 1
    fi
    setsid nohup "$BORE" local 2222 --to bore.pub > "$BORE_LOG" 2>&1 < /dev/null &
    local port="" i
    for i in $(seq 1 20); do
        sleep 1
        port="$(grep -oE 'bore\.pub:[0-9]+' "$BORE_LOG" 2>/dev/null | head -1 | cut -d: -f2)"
        [ -n "$port" ] && break
    done
    if [ -z "$port" ]; then
        log "bore tunnel failed to start (see $BORE_LOG)"
        return 1
    fi
    printf '%s\n' "$port" > "$PORT_FILE"
    log "tunnel up: bore.pub:$port -> 127.0.0.1:2222"
    notify "🖥 SSH 已就绪
ssh -p ${port} -i ~/komari_sandbox_key -o StrictHostKeyChecking=accept-new node@bore.pub

端口会在隧道重启后变化，以最新消息为准。"
    send_key_once
}

check_once() {
    start_server || return 1
    start_tunnel || return 1
}

log "ssh-tunnel started (once=$ONCE, interval=${INTERVAL}s)"
if [ "$ONCE" = true ]; then
    check_once
    exit $?
fi

while true; do
    check_once
    sleep "$INTERVAL"
done
