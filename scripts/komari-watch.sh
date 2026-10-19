#!/usr/bin/env bash
# komari-watch.sh - one-shot health check for the local Komari agent.
# Sends a Telegram alert only when the state changes (or with --force),
# so it is safe to run every minute from cron / a scheduled task.
#
# Usage:
#   ./komari-watch.sh
#   ./komari-watch.sh --force
#   ./komari-watch.sh --disk-threshold 90 --mem-threshold 90
#
# Exit codes: 0 = healthy, 1 = issues found, 2 = notification failed.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${TELEGRAM_NOTIFY:-$SCRIPT_DIR/telegram-notify.sh}"

KOMARI_DIR="${KOMARI_DIR:-$HOME/.local/share/komari}"
KOMARI_PID_FILE="${KOMARI_PID_FILE:-$KOMARI_DIR/agent.pid}"
KOMARI_LOG="${KOMARI_LOG:-$KOMARI_DIR/agent.log}"
KOMARI_ENDPOINT="${KOMARI_ENDPOINT:-https://komari.577591.xyz}"
DISK_PATH="${DISK_PATH:-/workspace}"
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
MEM_THRESHOLD="${MEM_THRESHOLD:-85}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/komari"
STATE_FILE="$STATE_DIR/watch.state"
FORCE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --endpoint) KOMARI_ENDPOINT="${2:?}"; shift 2 ;;
        --disk-threshold) DISK_THRESHOLD="${2:?}"; shift 2 ;;
        --mem-threshold) MEM_THRESHOLD="${2:?}"; shift 2 ;;
        --disk-path) DISK_PATH="${2:?}"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR"

issues=()

# 1. Agent process alive?
agent_pid=""
if [ -r "$KOMARI_PID_FILE" ]; then
    agent_pid="$(tr -dc '0-9' < "$KOMARI_PID_FILE")"
fi
if [ -n "$agent_pid" ] && kill -0 "$agent_pid" 2>/dev/null; then
    :
else
    agent_pid="$(pgrep -f 'komari-agent|(^|/)agent -e ' | head -n 1 || true)"
    if [ -z "$agent_pid" ]; then
        issues+=("agent 进程未运行")
    fi
fi

# 2. Dashboard endpoint reachable?
http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 10 --max-time 20 "$KOMARI_ENDPOINT" 2>/dev/null || echo 000)"
case "$http_code" in
    2*|3*) : ;;
    *) issues+=("面板不可达 (HTTP ${http_code})") ;;
esac

# 3. WebSocket state from the agent log (best effort).
if [ -r "$KOMARI_LOG" ]; then
    last_ws="$(grep -E 'WebSocket (connected|disconnected)' "$KOMARI_LOG" | tail -n 1 || true)"
    case "$last_ws" in
        *disconnected*) issues+=("WebSocket 已断开") ;;
    esac
    # The log is expected to be written at least every info-report-interval (default 5 min).
    last_mtime="$(stat -c '%Y' "$KOMARI_LOG" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ "$last_mtime" -gt 0 ] && [ $((now - last_mtime)) -gt 1800 ]; then
        issues+=("agent 日志超过 30 分钟无更新")
    fi
else
    issues+=("agent 日志不存在: $KOMARI_LOG")
fi

# 4. Disk usage.
if disk_usage="$(df -P "$DISK_PATH" 2>/dev/null | awk 'NR==2 {gsub("%", "", $5); print $5}')" \
    && [ -n "$disk_usage" ]; then
    if [ "$disk_usage" -ge "$DISK_THRESHOLD" ]; then
        issues+=("磁盘 ${DISK_PATH} 使用率 ${disk_usage}% (阈值 ${DISK_THRESHOLD}%)")
    fi
fi

# 5. Memory usage (MemAvailable-based).
mem_total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_avail="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "$mem_total" -gt 0 ] && [ "$mem_avail" -gt 0 ]; then
    mem_usage=$(( (mem_total - mem_avail) * 100 / mem_total ))
    if [ "$mem_usage" -ge "$MEM_THRESHOLD" ]; then
        issues+=("内存使用率 ${mem_usage}% (阈值 ${MEM_THRESHOLD}%)")
    fi
fi

if [ ${#issues[@]} -eq 0 ]; then
    current="OK"
else
    current="$(printf '%s; ' "${issues[@]}")"
    current="${current%; }"
fi

previous="$(cat "$STATE_FILE" 2>/dev/null || echo "UNKNOWN")"
timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
host="$(hostname 2>/dev/null || echo unknown)"

if [ "$FORCE" = true ] || [ "$current" != "$previous" ]; then
    issue_lines=""
    for issue in "${issues[@]}"; do
        issue_lines+="- ${issue}"$'\n'
    done

    if [ "$current" = "OK" ]; then
        message="✅ Komari 监控恢复正常
主机: ${host}
时间: ${timestamp}
agent PID: ${agent_pid:-n/a}
面板: ${KOMARI_ENDPOINT} (HTTP ${http_code})
磁盘 ${DISK_PATH}: ${disk_usage:-n/a}%
内存: ${mem_usage:-n/a}%"
    else
        message="⚠️ Komari 监控告警
主机: ${host}
时间: ${timestamp}
面板: ${KOMARI_ENDPOINT} (HTTP ${http_code})
磁盘 ${DISK_PATH}: ${disk_usage:-n/a}%
内存: ${mem_usage:-n/a}%

问题:
${issue_lines%$'\n'}"
    fi

    if ! "$NOTIFY" "$message" >/dev/null; then
        echo "failed to send telegram notification" >&2
        exit 2
    fi
    printf '%s\n' "$current" > "$STATE_FILE"
    echo "alert sent: $current"
else
    echo "no change: $current"
fi

[ "$current" = "OK" ] && exit 0 || exit 1
