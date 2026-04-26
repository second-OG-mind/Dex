#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# DEX Dashboard — Telegram Alert Sender
# Usage: telegram-alert.sh "<message>"
# Reads TELEGRAM_BOT_TOKEN from ~/.openclaw/.env
# Chat ID: 5164722027 (owner DM)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

source ~/.openclaw/.env 2>/dev/null || true

CHAT_ID="5164722027"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
MESSAGE="${1:-[DEX] Alert (no message provided)}"

if [ -z "$BOT_TOKEN" ]; then
  echo "[telegram-alert] TELEGRAM_BOT_TOKEN not set — skipping" >&2
  exit 1
fi

PAYLOAD=$(python3 -c "
import json, sys
msg = sys.argv[1]
print(json.dumps({'chat_id': '${CHAT_ID}', 'text': msg, 'parse_mode': 'HTML'}))
" "$MESSAGE")

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
  echo "[telegram-alert] sent (HTTP $HTTP_CODE)"
else
  echo "[telegram-alert] FAILED (HTTP $HTTP_CODE)" >&2
  exit 1
fi
