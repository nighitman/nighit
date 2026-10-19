#!/usr/bin/env bash
# telegram-notify.sh - send a text message or a file to Telegram via Bot API.
#
# Credentials are read from an env file (default: ~/.config/komari/telegram.env):
#   TELEGRAM_BOT_TOKEN=123456789:AA...
#   TELEGRAM_CHAT_ID=123456789
#   TELEGRAM_PARSE_MODE=            # optional: MarkdownV2 / HTML
#
# Usage:
#   ./telegram-notify.sh "hello"
#   ./telegram-notify.sh --silent "nightly build passed"
#   ./telegram-notify.sh --file /path/report.txt --caption "build report"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${TELEGRAM_ENV_FILE:-$HOME/.config/komari/telegram.env}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
fi

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set (looked in $ENV_FILE)}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is not set (looked in $ENV_FILE)}"

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
CHUNK_LIMIT=3900

usage() {
    cat <<'EOF'
Usage: telegram-notify.sh [options] [text]

Options:
  -f, --file <path>       Send a document instead of a text message
  -c, --caption <text>    Caption for --file (max 1024 chars)
  -t, --text <text>       Message text (alternative to positional text)
  -s, --silent            Send without notification sound
      --thread <id>       Forum topic / message thread id
  -h, --help              Show this help

Environment:
  TELEGRAM_ENV_FILE       Credentials file (default: ~/.config/komari/telegram.env)
  TELEGRAM_PARSE_MODE     Optional parse mode: MarkdownV2 or HTML
EOF
}

FILE=""
CAPTION=""
TEXT=""
SILENT=false
THREAD=""

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--file)
            FILE="${2:?--file requires a path}"
            shift 2
            ;;
        -c|--caption)
            CAPTION="${2:-}"
            shift 2
            ;;
        -t|--text)
            TEXT="${2:-}"
            shift 2
            ;;
        -s|--silent)
            SILENT=true
            shift
            ;;
        --thread)
            THREAD="${2:?--thread requires an id}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            TEXT="${*:-}"
            break
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -z "$TEXT" ]; then
                TEXT="$1"
            else
                TEXT="$TEXT $1"
            fi
            shift
            ;;
    esac
done

api() {
    curl -sS --connect-timeout 10 --max-time 60 "$@"
}

check_response() {
    local response="$1"
    if ! printf '%s' "$response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("ok") else 1)
'; then
        echo "telegram API error: $response" >&2
        return 1
    fi
}

send_file() {
    local -a args=(-F "chat_id=${TELEGRAM_CHAT_ID}" -F "document=@${FILE}")
    if [ -n "$CAPTION" ]; then
        args+=(-F "caption=${CAPTION:0:1024}")
    fi
    if [ "$SILENT" = true ]; then
        args+=(-F "disable_notification=true")
    fi
    if [ -n "$THREAD" ]; then
        args+=(-F "message_thread_id=${THREAD}")
    fi
    check_response "$(api -X POST "${args[@]}" "${API}/sendDocument")"
}

send_text() {
    local text="$1"
    local chunk
    # Split on character boundaries (not bytes) into chunks under the API limit.
    while IFS= read -r -d '' chunk; do
        local -a args=(
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
            --data-urlencode "text=${chunk}"
            -d "disable_web_page_preview=true"
        )
        if [ "$SILENT" = true ]; then
            args+=(-d "disable_notification=true")
        fi
        if [ -n "$THREAD" ]; then
            args+=(-d "message_thread_id=${THREAD}")
        fi
        if [ -n "${TELEGRAM_PARSE_MODE:-}" ]; then
            args+=(--data-urlencode "parse_mode=${TELEGRAM_PARSE_MODE}")
        fi
        check_response "$(api -X POST "${args[@]}" "${API}/sendMessage")"
    done < <(printf '%s' "$text" | python3 -c '
import sys
limit = 3900
data = sys.stdin.buffer.read().decode("utf-8")
for i in range(0, len(data), limit):
    sys.stdout.buffer.write(data[i:i + limit].encode("utf-8"))
    sys.stdout.buffer.write(b"\x00")
')
}

if [ -n "$FILE" ]; then
    [ -r "$FILE" ] || { echo "cannot read file: $FILE" >&2; exit 2; }
    send_file
    echo "telegram: file sent (${FILE})"
else
    [ -n "$TEXT" ] || { echo "nothing to send (provide text or --file)" >&2; usage >&2; exit 2; }
    send_text "$TEXT"
    echo "telegram: message sent"
fi
