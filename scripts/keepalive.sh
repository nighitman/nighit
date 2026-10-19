#!/usr/bin/env bash
# keepalive.sh - restart the Komari agent / Telegram bot if they die.
#
# This only works while the container is alive; it cannot survive the sandbox
# being torn down and it cannot keep the Cline session itself alive.
#
# Usage:
#   ./keepalive.sh --once            # check and restart once
#   ./keepalive.sh                   # loop forever (default interval 60s)
#   ./keepalive.sh --interval 30
#   ./keepalive.sh --no-notify       # do not send Telegram restart alerts
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOMARI_DIR="${KOMARI_DIR:-$HOME/.local/share/komari}"
BOT_SCRIPT="${BOT_SCRIPT:-$SCRIPT_DIR/telegram-bot.py}"
AGENT_ENV="${AGENT_ENV:-$HOME/.config/komari/agent.env}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/komari"
LOG_FILE="$STATE_DIR/keepalive.log"
NOTIFY="$SCRIPT_DIR/telegram-notify.sh"
INTERVAL=60
ONCE=false
SEND_NOTIFY=true
NOTIFY_COOLDOWN=600

while [ $# -gt 0 ]; do
    case "$1" in
        --once) ONCE=true; shift ;;
        --interval) INTERVAL="${2:?}"; shift 2 ;;
        --no-notify) SEND_NOTIFY=false; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

notify() {
    local key="$1" message="$2" stamp="$STATE_DIR/notify-${1}.stamp"
    [ "$SEND_NOTIFY" = true ] || return 0
    [ -x "$NOTIFY" ] || return 0
    local now last=0
    now="$(date +%s)"
    [ -r "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
    if [ $((now - last)) -ge "$NOTIFY_COOLDOWN" ]; then
        "$NOTIFY" --silent "$message" >/dev/null 2>&1 || true
        printf '%s\n' "$now" > "$stamp"
    fi
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then
        tail -n 3000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

agent_pid() {
    local pid
    pid="$(pgrep -x agent 2>/dev/null | head -n 1)"
    if [ -n "$pid" ]; then
        printf '%s\n' "$pid"
        return 0
    fi
    if [ -r "$KOMARI_DIR/agent.pid" ]; then
        pid="$(tr -dc '0-9' < "$KOMARI_DIR/agent.pid")"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "$pid"
            return 0
        fi
    fi
    return 1
}

bot_pid() {
    pgrep -f '^python3 /workspace/scripts/telegram-bot\.py$' 2>/dev/null | head -n 1
}

start_agent() {
    if [ ! -r "$AGENT_ENV" ]; then
        log "agent down but $AGENT_ENV is missing; cannot restart"
        return 1
    fi
    # shellcheck source=/dev/null
    . "$AGENT_ENV"
    if [ -z "${KOMARI_ENDPOINT:-}" ] || [ -z "${KOMARI_AUTO_DISCOVERY_KEY:-}" ]; then
        log "agent env incomplete; cannot restart"
        return 1
    fi
    (
        cd "$KOMARI_DIR" || exit 1
        # shellcheck disable=SC2086
        setsid nohup ./agent -e "$KOMARI_ENDPOINT" \
            --auto-discovery "$KOMARI_AUTO_DISCOVERY_KEY" \
            ${KOMARI_EXTRA_ARGS:-} >> agent.log 2>&1 < /dev/null &
    )
    sleep 2
    local pid
    pid="$(agent_pid)" || { log "agent restart failed"; return 1; }
    printf '%s\n' "$pid" > "$KOMARI_DIR/agent.pid"
    log "agent restarted (PID $pid)"
    notify agent "🔄 Keepalive: Komari agent 已自动重启 (PID $pid)"
}

start_bot() {
    setsid nohup python3 "$BOT_SCRIPT" >> "$STATE_DIR/bot.log" 2>&1 < /dev/null &
    sleep 2
    local pid
    pid="$(bot_pid)"
    if [ -z "$pid" ]; then
        log "bot restart failed (check $STATE_DIR/bot.log)"
        return 1
    fi
    printf '%s\n' "$pid" > "$STATE_DIR/bot.pid"
    log "telegram bot restarted (PID $pid)"
    notify bot "🔄 Keepalive: Telegram bot 已自动重启 (PID $pid)"
}

check_once() {
    local pid
    if pid="$(agent_pid)"; then
        :
    else
        log "agent is down, restarting..."
        start_agent
    fi
    if pid="$(bot_pid)"; then
        :
    else
        log "telegram bot is down, restarting..."
        start_bot
    fi
}

log "keepalive started (once=$ONCE, interval=${INTERVAL}s)"
if [ "$ONCE" = true ]; then
    check_once
    exit 0
fi

while true; do
    check_once
    rotate_log
    sleep "$INTERVAL"
done
