#!/usr/bin/env bash
# argo-node.sh - keep an Xray VLESS/WS node behind a Cloudflare Quick Tunnel
# alive, and regenerate the vless:// link + base64 subscription when the
# trycloudflare.com hostname changes.
#
# Usage:
#   ./argo-node.sh --once     # ensure everything, print links
#   ./argo-node.sh            # loop forever (default interval 20s)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGO_DIR="${ARGO_DIR:-$HOME/.local/opt/argo}"
XRAY="${XRAY:-$ARGO_DIR/xray}"
CF="${CF:-$ARGO_DIR/cloudflared}"
CONFIG="${XRAY_CONFIG:-$HOME/.config/komari/argo/xray-server.json}"
TOKEN_FILE="${TUNNEL_TOKEN_FILE:-$HOME/.config/komari/argo/tunnel.token}"
NAMED_ENV="${NAMED_ENV:-$HOME/.config/komari/argo/named.env}"
if [ -f "$NAMED_ENV" ]; then
    # shellcheck source=/dev/null
    . "$NAMED_ENV"
fi
NAMED_HOST="${NAMED_HOST:-}"
NAMED_SUB_HOST="${NAMED_SUB_HOST:-}"
UUID_FILE="$HOME/.config/komari/argo/uuid"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/komari"
SUB_DIR="$STATE_DIR/argo-sub"
NOTIFY="${TELEGRAM_NOTIFY:-$SCRIPT_DIR/telegram-notify.sh}"
INTERVAL=20
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

mkdir -p "$SUB_DIR" "$(dirname "$CONFIG")"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$STATE_DIR/argo.log"
}

notify() {
    [ "$SEND_NOTIFY" = true ] || return 0
    [ -x "$NOTIFY" ] || return 0
    "$NOTIFY" --silent "$1" >/dev/null 2>&1 || true
}

ensure_config() {
    [ -f "$CONFIG" ] && [ -f "$UUID_FILE" ] && return 0
    local uuid
    uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    printf '%s\n' "$uuid" > "$UUID_FILE"
    cat > "$CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 10000,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "/argo"}}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    log "generated new xray config (uuid=$uuid)"
}

ensure_xray() {
    if pgrep -f 'xray run -c .*xray-server\.json$' >/dev/null 2>&1; then
        return 0
    fi
    setsid nohup "$XRAY" run -c "$CONFIG" >> "$STATE_DIR/argo-xray.log" 2>&1 < /dev/null &
    sleep 2
    if ! pgrep -f 'xray run -c .*xray-server\.json$' >/dev/null 2>&1; then
        log "xray failed to start"
        return 1
    fi
    log "xray started"
}

ensure_named_tunnel() {
    if pgrep -f 'cloudflared tunnel run --token-file .*tunnel\.token' >/dev/null 2>&1; then
        return 0
    fi
    : > "$STATE_DIR/argo-named-cf.log"
    setsid nohup "$CF" tunnel run --token-file "$TOKEN_FILE" \
        >> "$STATE_DIR/argo-named-cf.log" 2>&1 < /dev/null &
    local i
    for i in $(seq 1 20); do
        sleep 1
        if grep -q 'Registered tunnel connection' "$STATE_DIR/argo-named-cf.log" 2>/dev/null; then
            log "named tunnel connected"
            return 0
        fi
    done
    log "named tunnel failed to connect"
    return 1
}

stop_quick_tunnels() {
    local p
    for p in $(ps -C cloudflared -o pid=,args= | awk '/tunnel --url http:\/\/127\.0\.0\.1:(10000|18080)/ {print $1}'); do
        kill "$p" 2>/dev/null
    done
}

# start_cf <target-url> <logfile> <hostfile> <match-pattern>
start_cf() {
    local target="$1" logfile="$2" hostfile="$3" pattern="$4" host=""
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
        : > "$logfile"
        setsid nohup "$CF" tunnel --url "$target" --no-autoupdate > "$logfile" 2>&1 < /dev/null &
        local i
        for i in $(seq 1 25); do
            sleep 1
            host="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$logfile" 2>/dev/null | head -1)"
            [ -n "$host" ] && break
        done
        if [ -z "$host" ]; then
            log "cloudflared failed for $target"
            return 1
        fi
        printf '%s\n' "${host#https://}" > "$hostfile"
        log "cloudflared up: ${host#https://} -> $target"
        return 0
    fi
    [ -s "$hostfile" ] && return 0
    host="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$logfile" 2>/dev/null | head -1)"
    if [ -n "$host" ]; then
        printf '%s\n' "${host#https://}" > "$hostfile"
        return 0
    fi
    return 1
}

ensure_http() {
    if pgrep -f 'http\.server 18080' >/dev/null 2>&1; then
        return 0
    fi
    setsid nohup python3 -m http.server 18080 --bind 127.0.0.1 --directory "$SUB_DIR" \
        >> "$STATE_DIR/argo-http.log" 2>&1 < /dev/null &
    sleep 1
    if ! pgrep -f 'http\.server 18080' >/dev/null 2>&1; then
        log "subscription http server failed (port 18080 busy?)"
        return 1
    fi
    log "subscription http server started"
}

write_links() {
    local host subhost uuid link suburl signature previous sub_line=""
    host="$(cat "$STATE_DIR/argo-host" 2>/dev/null || true)"
    subhost="$(cat "$STATE_DIR/argo-sub-host" 2>/dev/null || true)"
    uuid="$(cat "$UUID_FILE")"
    [ -n "$host" ] || { log "no node hostname yet"; return 1; }

    link="vless://${uuid}@${host}:443?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=%2Fargo#Argo-Sandbox"
    printf '%s\n' "$link" > "$SUB_DIR/vless.txt"
    base64 -w0 "$SUB_DIR/vless.txt" > "$SUB_DIR/sub.txt"

    if [ -n "$subhost" ]; then
        suburl="https://${subhost}/sub.txt"
        printf '%s\n' "$suburl" > "$SUB_DIR/url"
        sub_line="订阅链接: ${suburl}"$'\n'
    else
        suburl="none"
        rm -f "$SUB_DIR/url"
    fi

    signature="${host}|${suburl}"
    previous="$(cat "$STATE_DIR/argo-links.sig" 2>/dev/null || true)"
    if [ "$signature" != "$previous" ]; then
        printf '%s\n' "$signature" > "$STATE_DIR/argo-links.sig"
        notify "🛰 Argo 节点已就绪
${sub_line}直连节点: ${link}

提示: 节点域名为固定域名，隧道重连后链接不变。"
        log "links updated: host=${host} sub=${suburl}"
    fi
}

print_links() {
    echo "direct: $(cat "$SUB_DIR/vless.txt" 2>/dev/null)"
    echo "subscription: $(cat "$SUB_DIR/url" 2>/dev/null)"
}

check_once() {
    ensure_config || return 1
    ensure_xray || return 1

    if [ -s "$TOKEN_FILE" ] && [ -n "$NAMED_HOST" ]; then
        ensure_named_tunnel || return 1
        stop_quick_tunnels
        printf '%s\n' "$NAMED_HOST" > "$STATE_DIR/argo-host"
        printf '%s\n' "$NAMED_SUB_HOST" > "$STATE_DIR/argo-sub-host"
        if [ -n "$NAMED_SUB_HOST" ]; then
            ensure_http || true
        fi
        write_links
        return $?
    fi

    start_cf "http://127.0.0.1:10000" "$STATE_DIR/argo-cf.log" \
        "$STATE_DIR/argo-host" 'cloudflared tunnel --url http://127\.0\.0\.1:10000' || return 1
    ensure_http || return 1
    start_cf "http://127.0.0.1:18080" "$STATE_DIR/argo-sub-cf.log" \
        "$STATE_DIR/argo-sub-host" 'cloudflared tunnel --url http://127\.0\.0\.1:18080' || true
    write_links
}

log "argo-node started (once=$ONCE, interval=${INTERVAL}s)"
if [ "$ONCE" = true ]; then
    check_once
    print_links
    exit $?
fi

while true; do
    check_once
    sleep "$INTERVAL"
done
