#!/usr/bin/env bash
# argo-health.sh - health check for the Argo node with state-aware notifications.
#
# Notify policy:
#   OK -> ABNORMAL : send alert
#   ABNORMAL stays : remind at most every ARGO_ALERT_REMIND seconds (default 1800)
#   ABNORMAL -> OK : send recovery message
#   OK stays       : silent (only append log)
#
# Usage:
#   ./argo-health.sh
#   ./argo-health.sh --dry-run     # print notifications instead of sending
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${TELEGRAM_NOTIFY:-$SCRIPT_DIR/telegram-notify.sh}"
HOST="${ARGO_HOST:-cline.mailking.dpdns.org}"
STATE_FILE="${ARGO_HEALTH_STATE:-$HOME/.local/state/komari/argo-health.state}"
LOG_FILE="${ARGO_HEALTH_LOG:-/workspace/.cline-scheduled/argo-keepalive.log}"
REMIND="${ARGO_ALERT_REMIND:-1800}"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")" 2>/dev/null

send() {
    local message="$1"
    if [ "$DRY_RUN" = true ]; then
        printf '[dry-run]\n%s\n' "$message"
        return 0
    fi
    [ -x "$NOTIFY" ] || return 1
    "$NOTIFY" --silent "$message" >/dev/null 2>&1 || true
}

issues=()

for name in xray caddy cloudflared; do
    pgrep -x "$name" >/dev/null 2>&1 || issues+=("${name} 未运行")
done
pgrep -f '^python3 /workspace/scripts/telegram-bot\.py$' >/dev/null 2>&1 \
    || issues+=("telegram bot 未运行")
pgrep -x agent >/dev/null 2>&1 || issues+=("komari agent 未运行")

sub_code="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "https://${HOST}/sub.txt" 2>/dev/null || true)"
sub_code="${sub_code:-000}"
[ "$sub_code" = "200" ] || issues+=("订阅 HTTP ${sub_code}")

root_code="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "https://${HOST}/" 2>/dev/null || true)"
root_code="${root_code:-000}"
case "$root_code" in
    400|404) : ;;
    *) issues+=("节点根路径 HTTP ${root_code}") ;;
esac

decoded="$(curl -sS -m 15 "https://${HOST}/sub.txt" 2>/dev/null | base64 -d 2>/dev/null | head -c 6 || true)"
[ "$decoded" = "vless:" ] || issues+=("订阅内容解码失败")

if [ ${#issues[@]} -eq 0 ]; then
    status="OK"
    detail="all checks passed"
else
    status="ABNORMAL"
    detail="$(IFS='; '; echo "${issues[*]}")"
fi

prev_status="UNKNOWN"
prev_alert=0
if [ -r "$STATE_FILE" ]; then
    IFS='|' read -r prev_status prev_alert < "$STATE_FILE" || true
    [[ "$prev_alert" =~ ^[0-9]+$ ]] || prev_alert=0
fi

now="$(date +%s)"
message=""

if [ "$status" = "ABNORMAL" ]; then
    if [ "$prev_status" != "ABNORMAL" ] || [ $((now - prev_alert)) -ge "$REMIND" ]; then
        message="⚠️ Argo 节点异常
主机: $(hostname)
时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
问题:
$(printf '%s\n' "${issues[@]}" | sed 's/^/- /')
订阅: HTTP ${sub_code} | 节点: HTTP ${root_code}"
        prev_alert="$now"
    fi
elif [ "$prev_status" = "ABNORMAL" ]; then
    message="✅ Argo 节点已恢复
主机: $(hostname)
时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
订阅: HTTP ${sub_code} | 节点: HTTP ${root_code}"
fi

[ -n "$message" ] && send "$message"

printf '%s|%s\n' "$status" "$prev_alert" > "$STATE_FILE"
printf '%s | %s | sub=%s | node=%s | %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S%z')" "$status" "$sub_code" "$root_code" "$detail" >> "$LOG_FILE"
printf '%s: %s\n' "$status" "$detail"

[ "$status" = "OK" ]
