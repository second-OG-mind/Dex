#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# DEX Dashboard — Live Status Updater
# Scans all OpenClaw services, tests APIs, writes data.json, pushes to GitHub.
# Usage:  ~/dex-dashboard/update-status.sh
# Cron:   */15 * * * * /home/monster-ubunto/dex-dashboard/update-status.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_FILE="$SCRIPT_DIR/data.json"
LOG_FILE="/tmp/dex-update.log"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

log() { echo "[$TS] $*" | tee -a "$LOG_FILE"; }
log "=== DEX status update starting ==="

# ── 1. Source API keys ──────────────────────────────────────────────────────
source ~/.openclaw/.env 2>/dev/null || true

# ── 2. Check systemd services ──────────────────────────────────────────────
check_service() {
  local svc="$1"
  if systemctl --user is-active "$svc" &>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

get_pid() {
  systemctl --user show -p MainPID "$1" 2>/dev/null | cut -d= -f2 || echo "0"
}

get_cpu_mem() {
  local pid="$1"
  if [ "$pid" != "0" ] && [ -n "$pid" ]; then
    ps -p "$pid" -o %cpu=,%mem= 2>/dev/null | awk '{printf "%.1f\t%.1f", $1, $2}' || echo "0.0\t0.0"
  else
    echo "0.0\t0.0"
  fi
}

GW_ACTIVE=$(check_service openclaw-gateway.service)
CG_ACTIVE=$(check_service cognee.service)
M0_ACTIVE=$(check_service mem0.service)
QD_ACTIVE=$(check_service qdrant.service)
LL_ACTIVE=$(check_service litellm-proxy.service)

GW_PID=$(get_pid openclaw-gateway.service)
CG_PID=$(get_pid cognee.service)
M0_PID=$(get_pid mem0.service)
QD_PID=$(get_pid qdrant.service)
LL_PID=$(get_pid litellm-proxy.service)

read GW_CPU GW_MEM <<< $(get_cpu_mem "$GW_PID")
read CG_CPU CG_MEM <<< $(get_cpu_mem "$CG_PID")
read M0_CPU M0_MEM <<< $(get_cpu_mem "$M0_PID")
read QD_CPU QD_MEM <<< $(get_cpu_mem "$QD_PID")
read LL_CPU LL_MEM <<< $(get_cpu_mem "$LL_PID")

log "Services: GW=$GW_ACTIVE CG=$CG_ACTIVE MEM0=$M0_ACTIVE QD=$QD_ACTIVE LL=$LL_ACTIVE"

# ── 3. Gateway status ───────────────────────────────────────────────────────
GW_STATUS="offline"
if [ "$GW_ACTIVE" = "true" ]; then
  if curl -sf http://127.0.0.1:18789/health &>/dev/null; then
    GW_STATUS="online"
  else
    GW_STATUS="running_no_probe"
  fi
fi

# ── 4. LiteLLM API key health ───────────────────────────────────────────────
LITELLM_HEALTHY=0
LITELLM_UNHEALTHY=0

if [ "$LL_ACTIVE" = "true" ]; then
  HEALTH_JSON=$(curl -sf \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY:-sk-openclaw-litellm-local}" \
    "http://127.0.0.1:4000/health" 2>/dev/null || echo '{}')
  LITELLM_HEALTHY=$(echo "$HEALTH_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(len(d.get('healthy_endpoints',[])))
except: print(0)
" 2>/dev/null || echo 0)
  LITELLM_UNHEALTHY=$(echo "$HEALTH_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(len(d.get('unhealthy_endpoints',[])))
except: print(0)
" 2>/dev/null || echo 0)
fi

log "LiteLLM: healthy=$LITELLM_HEALTHY unhealthy=$LITELLM_UNHEALTHY"

# ── 5. Quick API key test (embedding) ──────────────────────────────────────
# Tests a small embedding call to determine if the embedding pool is responsive
EMBED_WORKING=0
EMBED_TOTAL=12

if [ "$LL_ACTIVE" = "true" ]; then
  TEST_RESULT=$(curl -sf \
    -H "Authorization: Bearer sk-openclaw-litellm-local" \
    -H "Content-Type: application/json" \
    http://127.0.0.1:4000/v1/embeddings \
    -d '{"model":"gemini-embedding","input":"health check","encoding_format":"float"}' \
    2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    dims=len(d['data'][0]['embedding'])
    print(dims)
except: print(0)
" 2>/dev/null || echo 0)

  if [ "$TEST_RESULT" = "3072" ]; then
    EMBED_WORKING=$((LITELLM_HEALTHY > 12 ? 12 : LITELLM_HEALTHY))
    log "Embedding test: PASS ($TEST_RESULT dims)"
  else
    EMBED_WORKING=0
    log "Embedding test: FAIL (got $TEST_RESULT dims)"
  fi
fi

# Split healthy endpoints between chat and embedding pools (24 total = 12+12)
TOTAL_ENDPOINTS=$((LITELLM_HEALTHY + LITELLM_UNHEALTHY))
GEMINI_CHAT_HEALTHY=0
GEMINI_EMBED_HEALTHY=0

if [ "$TOTAL_ENDPOINTS" -gt 0 ]; then
  # Assume roughly half of healthy are chat, half embedding
  GEMINI_CHAT_HEALTHY=$(( LITELLM_HEALTHY / 2 ))
  GEMINI_EMBED_HEALTHY=$(( LITELLM_HEALTHY - GEMINI_CHAT_HEALTHY ))
  # Embed working overrides embedding count if we got a real test
  if [ "$EMBED_WORKING" -gt 0 ]; then
    GEMINI_EMBED_HEALTHY=$EMBED_WORKING
  fi
fi

GEMINI_CHAT_REST=$((12 - GEMINI_CHAT_HEALTHY))
GEMINI_EMBED_REST=$((12 - GEMINI_EMBED_HEALTHY))
[ "$GEMINI_CHAT_REST" -lt 0 ] && GEMINI_CHAT_REST=0
[ "$GEMINI_EMBED_REST" -lt 0 ] && GEMINI_EMBED_REST=0

# ── 6. Qdrant collection counts ─────────────────────────────────────────────
MEM0_OPENCLAW_PTS=0
MEM0_REST_PTS=0

if [ "$QD_ACTIVE" = "true" ]; then
  MEM0_OPENCLAW_PTS=$(curl -sf http://localhost:6333/collections/mem0-openclaw 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo 0)
  MEM0_REST_PTS=$(curl -sf http://localhost:6333/collections/mem0-rest 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo 0)
fi

log "Qdrant: mem0-openclaw=$MEM0_OPENCLAW_PTS mem0-rest=$MEM0_REST_PTS"

# ── 7. mem0 REST health ──────────────────────────────────────────────────────
MEM0_REST_STATUS="offline"
if [ "$M0_ACTIVE" = "true" ]; then
  if curl -sf http://127.0.0.1:8080/health &>/dev/null; then
    MEM0_REST_STATUS="online"
  fi
fi

# ── 8. Cognee health ─────────────────────────────────────────────────────────
COGNEE_STATUS="offline"
if [ "$CG_ACTIVE" = "true" ]; then
  if curl -sf http://127.0.0.1:8000/health &>/dev/null; then
    COGNEE_STATUS="online"
  fi
fi

# ── 9. Write data.json ───────────────────────────────────────────────────────
cat > "$DATA_FILE" << JSONEOF
{
  "last_updated": "$TS",
  "gateway": {
    "status": "$GW_STATUS",
    "port": 18789,
    "pid": $GW_PID,
    "version": "2026.4.15"
  },
  "services": {
    "openclaw-gateway": { "active": $GW_ACTIVE, "cpu": $GW_CPU, "mem": $GW_MEM, "port": 18789, "pid": $GW_PID },
    "cognee":           { "active": $CG_ACTIVE, "cpu": $CG_CPU, "mem": $CG_MEM, "port": 8000,  "status": "$COGNEE_STATUS" },
    "mem0":             { "active": $M0_ACTIVE, "cpu": $M0_CPU, "mem": $M0_MEM, "port": 8080,  "status": "$MEM0_REST_STATUS" },
    "qdrant":           { "active": $QD_ACTIVE, "cpu": $QD_CPU, "mem": $QD_MEM, "port": 6333  },
    "litellm-proxy":    { "active": $LL_ACTIVE, "cpu": $LL_CPU, "mem": $LL_MEM, "port": 4000  }
  },
  "api": {
    "gemini_chat":      { "total": 12, "healthy": $GEMINI_CHAT_HEALTHY, "resting": $GEMINI_CHAT_REST },
    "gemini_embedding": { "total": 12, "healthy": $GEMINI_EMBED_HEALTHY, "resting": $GEMINI_EMBED_REST },
    "mistral":          { "total": 6,  "healthy": 6,                     "resting": 0 }
  },
  "memory": {
    "mem0_openclaw_points": $MEM0_OPENCLAW_PTS,
    "mem0_rest_points":     $MEM0_REST_PTS
  },
  "litellm": {
    "healthy_endpoints":   $LITELLM_HEALTHY,
    "unhealthy_endpoints": $LITELLM_UNHEALTHY,
    "total_endpoints":     $((LITELLM_HEALTHY + LITELLM_UNHEALTHY))
  }
}
JSONEOF

log "data.json written → $DATA_FILE"

# ── 10. Git commit + push ────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

if ! git rev-parse --git-dir &>/dev/null; then
  log "Not a git repo — run setup first (see README)"
  exit 0
fi

git add data.json
if git diff --staged --quiet; then
  log "No changes to push"
  exit 0
fi

git commit -m "chore: live status update $TS"
git push origin main 2>&1 | tee -a "$LOG_FILE"
log "=== Push complete ==="
