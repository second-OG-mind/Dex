#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# DEX Dashboard — inotify trigger handler
# Called by dex-watcher.sh when a watched OpenClaw config file changes.
# Debounces: ignores calls if an update ran within the last 60 seconds.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK="/tmp/dex-inotify.lock"
LOG="/tmp/dex-inotify.log"
DEBOUNCE_TTL=60

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ -f "$LOCK" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  if [ "$AGE" -lt "$DEBOUNCE_TTL" ]; then
    echo "[$TS] debounce skip — last push ${AGE}s ago (changed: $*)" >> "$LOG"
    exit 0
  fi
fi

touch "$LOCK"
echo "[$TS] inotify TRIGGER — changed: $*" >> "$LOG"
bash "$SCRIPT_DIR/update-status.sh" >> "$LOG" 2>&1
echo "[$TS] inotify push complete" >> "$LOG"
