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
    ps -p "$pid" -o %cpu=,%mem= 2>/dev/null | awk '{printf "%.1f %.1f", $1, $2}' || echo "0.0 0.0"
  else
    echo "0.0 0.0"
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
EMBED_TOTAL=28

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
    EMBED_WORKING=$((LITELLM_HEALTHY > 28 ? 28 : LITELLM_HEALTHY))
    log "Embedding test: PASS ($TEST_RESULT dims)"
  else
    EMBED_WORKING=0
    log "Embedding test: FAIL (got $TEST_RESULT dims)"
  fi
fi

# Per-pool health is derived from key-states.json in the Python block below.
# Do not compute from raw endpoint counts — those include aliases and are unreliable.

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

# ── 9. Write data.json via Python (safe JSON serialization) ──────────────────
# Passes all primitive values as env vars; Python reads key-states.json
# directly from disk — no shell string embedding of JSON.
export DJ_TS="$TS" DJ_FILE="$DATA_FILE"
export DJ_GW_STATUS="$GW_STATUS" DJ_GW_PID="$GW_PID"
export DJ_GW_ACTIVE="$GW_ACTIVE" DJ_GW_CPU="$GW_CPU" DJ_GW_MEM="$GW_MEM"
export DJ_CG_ACTIVE="$CG_ACTIVE" DJ_CG_CPU="$CG_CPU" DJ_CG_MEM="$CG_MEM" DJ_CG_STATUS="$COGNEE_STATUS"
export DJ_M0_ACTIVE="$M0_ACTIVE" DJ_M0_CPU="$M0_CPU" DJ_M0_MEM="$M0_MEM" DJ_M0_STATUS="$MEM0_REST_STATUS"
export DJ_QD_ACTIVE="$QD_ACTIVE" DJ_QD_CPU="$QD_CPU" DJ_QD_MEM="$QD_MEM"
export DJ_LL_ACTIVE="$LL_ACTIVE" DJ_LL_CPU="$LL_CPU" DJ_LL_MEM="$LL_MEM"
export DJ_LL_H="$LITELLM_HEALTHY" DJ_LL_U="$LITELLM_UNHEALTHY"
export DJ_MEM_OC="$MEM0_OPENCLAW_PTS" DJ_MEM_R="$MEM0_REST_PTS"

python3 << 'DATAEOF'
import json, os
e = os.environ.get
def b(v): return (v or '').lower() == 'true'
def f(v): return float(v or '0')
def i(v):
    try: return int(float(v or '0'))
    except: return 0

try:
    ks = json.load(open('/home/monster-ubunto/.openclaw/key-states.json'))
except Exception as ex:
    ks = {'schema_version': '1.1', 'pools': {}, 'error': str(ex)}

def pool_counts(ks, pool_name, total):
    p = ks.get('pools', {}).get(pool_name, {})
    resting = len(p.get('resting_keys', []))
    healthy = max(0, total - resting)
    return healthy, resting

gemma_h,   gemma_r   = pool_counts(ks, 'gemma-chat',         28)
fallbk_h,  fallbk_r  = pool_counts(ks, 'gemma-fallback',     28)
intern_h,  intern_r  = pool_counts(ks, 'gemma-internal',     28)
agentc_h,  agentc_r  = pool_counts(ks, 'gemma-agentic',      28)
embed_h,   embed_r   = pool_counts(ks, 'gemini-embedding',   28)
embed2_h,  embed2_r  = pool_counts(ks, 'gemini-embedding-2', 28)

data = {
    'last_updated': e('DJ_TS', ''),
    'gateway': {
        'status':  e('DJ_GW_STATUS', 'offline'),
        'port':    18789,
        'pid':     i(e('DJ_GW_PID', '0')),
        'version': '2026.4.27',
    },
    'services': {
        'openclaw-gateway': {'active': b(e('DJ_GW_ACTIVE')), 'cpu': f(e('DJ_GW_CPU')), 'mem': f(e('DJ_GW_MEM')), 'port': 18789, 'pid': i(e('DJ_GW_PID'))},
        'cognee':           {'active': b(e('DJ_CG_ACTIVE')), 'cpu': f(e('DJ_CG_CPU')), 'mem': f(e('DJ_CG_MEM')), 'port': 8000,  'status': e('DJ_CG_STATUS', 'offline')},
        'mem0':             {'active': b(e('DJ_M0_ACTIVE')), 'cpu': f(e('DJ_M0_CPU')), 'mem': f(e('DJ_M0_MEM')), 'port': 8080,  'status': e('DJ_M0_STATUS', 'offline')},
        'qdrant':           {'active': b(e('DJ_QD_ACTIVE')), 'cpu': f(e('DJ_QD_CPU')), 'mem': f(e('DJ_QD_MEM')), 'port': 6333},
        'litellm-proxy':    {'active': b(e('DJ_LL_ACTIVE')), 'cpu': f(e('DJ_LL_CPU')), 'mem': f(e('DJ_LL_MEM')), 'port': 4000},
    },
    'api': {
        'gemma_chat':         {'total': 28, 'healthy': gemma_h,  'resting': gemma_r},
        'gemma_fallback':     {'total': 28, 'healthy': fallbk_h, 'resting': fallbk_r},
        'gemma_internal':     {'total': 28, 'healthy': intern_h, 'resting': intern_r},
        'gemma_agentic':      {'total': 28, 'healthy': agentc_h, 'resting': agentc_r},
        'gemini_embedding':   {'total': 28, 'healthy': embed_h,  'resting': embed_r},
        'gemini_embedding_2': {'total': 28, 'healthy': embed2_h, 'resting': embed2_r},
    },
    'memory': {
        'mem0_openclaw_points': i(e('DJ_MEM_OC')),
        'mem0_rest_points':     i(e('DJ_MEM_R')),
    },
    'litellm': {
        'healthy_endpoints':   i(e('DJ_LL_H')),
        'unhealthy_endpoints': i(e('DJ_LL_U')),
        'total_endpoints':     i(e('DJ_LL_H')) + i(e('DJ_LL_U')),
    },
    'key_states': ks,
}

with open(e('DJ_FILE'), 'w') as fh:
    json.dump(data, fh, indent=2)
print('data.json written OK')
DATAEOF

log "data.json written → $DATA_FILE"

# ── 11. Git commit + push ────────────────────────────────────────────────────
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
