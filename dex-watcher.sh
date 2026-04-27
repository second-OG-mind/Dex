#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# DEX Dashboard — inotify watch loop
# Watches ~/.openclaw/ recursively for writes to config files.
# Filters to: .env, openclaw.json, *.plugin.json, *.md (cognee docs).
# Fires on-config-change.sh with debounce on any match.
# Managed by dex-watcher.service (systemd user unit).
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRIGGER="$SCRIPT_DIR/on-config-change.sh"
LOG="/tmp/dex-inotify.log"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] dex-watcher started, watching ~/.openclaw/" >> "$LOG"

inotifywait -m -r \
  -e close_write,create,moved_to \
  --format '%w%f' \
  "$HOME/.openclaw/" \
  2>>"$LOG" \
| grep --line-buffered -E '(\.env|openclaw\.json|\.plugin\.json|\.md)$' \
| while IFS= read -r changed_file; do
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] watch hit: $changed_file" >> "$LOG"
    bash "$TRIGGER" "$changed_file"
  done

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] dex-watcher exited unexpectedly" >> "$LOG"
