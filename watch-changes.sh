#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# DEX Dashboard — Change Watcher
# Polls key volatile metrics every 3 min; triggers full update only on change.
# Cron: */3 * * * * /home/monster-ubunto/dex-dashboard/watch-changes.sh >> /tmp/dex-watch.log 2>&1
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="/tmp/dex-last-state"
UPDATE_SH="$SCRIPT_DIR/update-status.sh"
ALERT_SH="$SCRIPT_DIR/telegram-alert.sh"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

source ~/.openclaw/.env 2>/dev/null || true

# ── Snapshot the volatile metrics ──────────────────────────────────────────
svc_state() {
  local s=""
  for svc in openclaw-gateway cognee mem0 qdrant litellm-proxy; do
    if systemctl --user is-active "${svc}.service" &>/dev/null; then
      s+="${svc}:up "
    else
      s+="${svc}:down "
    fi
  done
  echo "$s"
}

litellm_counts() {
  if systemctl --user is-active "litellm-proxy.service" &>/dev/null; then
    HEALTH=$(curl -sf \
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY:-sk-openclaw-litellm-local}" \
      "http://127.0.0.1:4000/health" 2>/dev/null || echo '{}')
    echo "$HEALTH" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  h=len(d.get('healthy_endpoints',[]))
  u=len(d.get('unhealthy_endpoints',[]))
  print(f'h:{h} u:{u}')
except: print('h:? u:?')
" 2>/dev/null || echo "h:err"
    # Alert if ALL endpoints unhealthy (complete pool collapse)
    echo "$HEALTH" | python3 -c "
import sys,json,os
try:
  d=json.load(sys.stdin)
  h=len(d.get('healthy_endpoints',[]))
  u=len(d.get('unhealthy_endpoints',[]))
  if h==0 and u>0:
    print('ALL_DOWN')
except: pass
" 2>/dev/null | grep -q "ALL_DOWN" && \
      bash "$ALERT_SH" "🚨 <b>LiteLLM: All endpoints unhealthy</b>
healthy=0 unhealthy reported — full pool collapse detected.
Time: ${TS}" 2>/dev/null || true
  else
    # Service down — alert if it just went down (check previous state)
    if grep -q "litellm-proxy:up" "/tmp/dex-last-state" 2>/dev/null; then
      bash "$ALERT_SH" "🔴 <b>LiteLLM proxy went DOWN</b>
litellm-proxy.service is no longer active.
Time: ${TS}" 2>/dev/null || true
    fi
    echo "h:0 u:0"
  fi
}

# ── Silent-failure alerts for each layer ────────────────────────────────────
check_gateway_silent_fail() {
  if systemctl --user is-active "openclaw-gateway.service" &>/dev/null; then
    if ! curl -sf http://127.0.0.1:18789/health &>/dev/null; then
      bash "$ALERT_SH" "⚠️ <b>Layer 1 silent fail: Gateway process running but /health unreachable</b>
openclaw-gateway.service is active but not responding.
Time: ${TS}" 2>/dev/null || true
    fi
  fi
}

check_cognee_silent_fail() {
  if systemctl --user is-active "cognee.service" &>/dev/null; then
    if ! curl -sf http://127.0.0.1:8000/health &>/dev/null; then
      bash "$ALERT_SH" "⚠️ <b>Layer 2 silent fail: Cognee process running but /health unreachable</b>
cognee.service is active but not responding on port 8000.
Time: ${TS}" 2>/dev/null || true
    fi
  fi
}

check_mem0_silent_fail() {
  if systemctl --user is-active "mem0.service" &>/dev/null; then
    if ! curl -sf http://127.0.0.1:8080/health &>/dev/null; then
      bash "$ALERT_SH" "⚠️ <b>Layer 3 silent fail: Mem0 process running but /health unreachable</b>
mem0.service is active but not responding on port 8080.
Time: ${TS}" 2>/dev/null || true
    fi
  fi
}

qdrant_pts() {
  if systemctl --user is-active "qdrant.service" &>/dev/null; then
    local a b
    a=$(curl -sf http://localhost:6333/collections/mem0-openclaw 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo "?")
    b=$(curl -sf http://localhost:6333/collections/mem0-rest 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo "?")
    echo "oc:${a} rest:${b}"
  else
    echo "oc:0 rest:0"
  fi
}

# Run silent-fail checks on every poll (not just on state change)
check_gateway_silent_fail
check_cognee_silent_fail
check_mem0_silent_fail

CURRENT="$(svc_state)|$(litellm_counts)|$(qdrant_pts)"

# ── Compare with last known state ──────────────────────────────────────────
LAST=""
[ -f "$STATE_FILE" ] && LAST=$(cat "$STATE_FILE")

if [ "$CURRENT" = "$LAST" ]; then
  echo "[$TS] No change — skipping push"
  exit 0
fi

echo "[$TS] Change detected:"
echo "  OLD: $LAST"
echo "  NEW: $CURRENT"
echo "$CURRENT" > "$STATE_FILE"

# ── Trigger full update ─────────────────────────────────────────────────────
echo "[$TS] Triggering full update..."
bash "$UPDATE_SH"
echo "[$TS] Done."
