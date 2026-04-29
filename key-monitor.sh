#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# DEX Dashboard — API Key Monitor
#
# What it does:
#  - Queries LiteLLM /health for unhealthy endpoints
#  - Maps each unhealthy endpoint back to its GEMINI_API_KEY_N / GEMINI_MEM_KEY_N
#    env var by matching the masked suffix from the health response
#  - Deduplicates: KEY_1 appears in both gemini-flash and openai/gemini-flash —
#    counted once per pool
#  - Writes per-key resting entries to ~/.openclaw/key-states.json
#  - Sends Telegram alerts on first detection and on full-pool exhaustion
#
# Cron: */15 * * * * ~/dex-dashboard/key-monitor.sh >> /tmp/dex-keymon.log 2>&1
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# Allow systemctl --user to work from cron (no interactive DBus session in cron)
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALERT_SH="$SCRIPT_DIR/telegram-alert.sh"
KEY_STATES="/home/monster-ubunto/.openclaw/key-states.json"
FIRST_SEEN_DIR="/tmp/dex-key-first-seen"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOW_EPOCH=$(date +%s)

log() { echo "[$TS] $*"; }
alert() { bash "$ALERT_SH" "$1" 2>/dev/null || true; }

set -a; source ~/.openclaw/.env 2>/dev/null || true; set +a
mkdir -p "$FIRST_SEEN_DIR"

# ── Helper: next midnight PT = 07:00 UTC (PDT) / 08:00 UTC (PST) ─────────────
next_midnight_pt_epoch() {
  local month day offset
  month=$(date +%-m)
  day=$(date +%-d)
  offset=8
  if   [ "$month" -ge 4 ] && [ "$month" -le 10 ]; then offset=7
  elif [ "$month" -eq 3 ] && [ "$day" -ge 8 ];     then offset=7
  elif [ "$month" -eq 11 ] && [ "$day" -lt 7 ];    then offset=7
  fi
  local h today_midnight
  h=$(printf "%02d" "$offset")
  today_midnight=$(date -u -d "today ${h}:00" +%s 2>/dev/null || echo 0)
  if [ "$today_midnight" -le "$NOW_EPOCH" ]; then
    echo $((today_midnight + 86400))
  else
    echo "$today_midnight"
  fi
}

RECOVER_EPOCH=$(next_midnight_pt_epoch)
RECOVER_ISO=$(date -u -d "@$RECOVER_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

log "=== key-monitor run ==="
log "Next midnight PT recovery = $RECOVER_ISO"

# ── Ensure key-states.json exists ────────────────────────────────────────────
if [ ! -f "$KEY_STATES" ]; then
  echo '{"schema_version":"1.1","pools":{},"last_updated":null}' > "$KEY_STATES"
fi

# ── Check LiteLLM service ────────────────────────────────────────────────────
if ! systemctl --user is-active litellm-proxy.service &>/dev/null; then
  log "litellm-proxy not running — alerting"
  alert "⚠️ <b>LiteLLM proxy is DOWN</b>
litellm-proxy.service is not running.
Time: ${TS}"
  exit 0
fi

# ── Fetch health to temp file ─────────────────────────────────────────────────
HEALTH_TMP=$(mktemp /tmp/dex-health-XXXXXX.json)
curl -sf --max-time 20 \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY:-sk-openclaw-litellm-local}" \
  "http://127.0.0.1:4000/health" > "$HEALTH_TMP" 2>/dev/null \
  || echo '{"healthy_endpoints":[],"unhealthy_endpoints":[]}' > "$HEALTH_TMP"

HEALTH_SIZE=$(wc -c < "$HEALTH_TMP")
log "Health fetched (${HEALTH_SIZE} bytes)"

# ── Main Python block ─────────────────────────────────────────────────────────
# Pass bash vars via environment so we can safely quote the heredoc marker
# (prevents bash from expanding $VARIABLE patterns inside Python code).
export KEY_MON_HEALTH="$HEALTH_TMP"
export KEY_MON_STATES="$KEY_STATES"
export KEY_MON_TS="$TS"
export KEY_MON_RECOVER_EPOCH="$RECOVER_EPOCH"
export KEY_MON_RECOVER_ISO="$RECOVER_ISO"
export KEY_MON_NOW="$NOW_EPOCH"
export KEY_MON_FIRST_SEEN="$FIRST_SEEN_DIR"

MONITOR_OUTPUT=$(python3 << 'PYEOF'
import json, os, sys

health_file    = os.environ['KEY_MON_HEALTH']
states_file    = os.environ['KEY_MON_STATES']
ts             = os.environ['KEY_MON_TS']
recover_epoch  = int(os.environ['KEY_MON_RECOVER_EPOCH'])
recover_iso    = os.environ['KEY_MON_RECOVER_ISO']
now_epoch      = int(os.environ['KEY_MON_NOW'])
first_seen_dir = os.environ['KEY_MON_FIRST_SEEN']

# ── Pool definitions ──────────────────────────────────────────────────────────
# Plan H: 6 pools × 28 keys each (GEMINI_API_KEY_1-12 + GEMINI_MEM_KEY_1-12 + KEY_13-16)
# key_groups: list of (env_prefix, count) tuples — same key, independent model quota
# "aliases" are extra model_names in config routing the same keys (excluded from counts)
POOLS = {
    'gemma-chat': {
        'models':  ['gemini/gemma-3-27b-it'],
        'aliases': [],
        'key_groups': [('GEMINI_API_KEY_', 16), ('GEMINI_MEM_KEY_', 12)],
        'total': 28,
    },
    'gemma-fallback': {
        'models':  ['gemini/gemma-3-4b-it'],
        'aliases': [],
        'key_groups': [('GEMINI_API_KEY_', 16), ('GEMINI_MEM_KEY_', 12)],
        'total': 28,
    },
    'gemma-internal': {
        'models':  ['gemini/gemma-3-12b-it'],
        'aliases': ['openai/gemma-internal'],      # Cognee LLM alias
        'key_groups': [('GEMINI_API_KEY_', 16), ('GEMINI_MEM_KEY_', 12)],
        'total': 28,
    },
    'gemma-agentic': {
        'models':  ['gemini/gemma-4-31b-it'],
        'aliases': [],
        'key_groups': [('GEMINI_API_KEY_', 16), ('GEMINI_MEM_KEY_', 12)],
        'total': 28,
    },
    'gemini-embedding': {
        'models':  ['gemini/gemini-embedding-001'],
        'aliases': ['openai/gemini-embedding'],    # Cognee embedder alias
        'key_groups': [('GEMINI_API_KEY_', 16), ('GEMINI_MEM_KEY_', 12)],
        'total': 28,
    },
    'gemini-embedding-2': {
        'models':  ['gemini/gemini-embedding-2'],
        'aliases': [],
        'key_groups': [('GEMINI_API_KEY_', 16), ('GEMINI_MEM_KEY_', 12)],
        'total': 28,
    },
}

# ── Load env keys — supports multiple (prefix, count) groups per pool ──────────
def load_keys_multi(key_groups):
    keys = {}
    for prefix, count in key_groups:
        for i in range(1, count + 1):
            name = f'{prefix}{i}'
            val  = os.environ.get(name, '')
            if val:
                keys[name] = val
    return keys  # {key_name: key_value}

pool_keys = {pname: load_keys_multi(pdef['key_groups'])
             for pname, pdef in POOLS.items()}

# ── Parse health ───────────────────────────────────────────────────────────────
try:
    health = json.load(open(health_file))
except Exception as e:
    print(f'PARSE_ERR:{e}')
    health = {'healthy_endpoints': [], 'unhealthy_endpoints': []}

healthy_eps   = health.get('healthy_endpoints',   [])
unhealthy_eps = health.get('unhealthy_endpoints', [])

print(f'STATS:healthy={len(healthy_eps)}:unhealthy={len(unhealthy_eps)}')

def get_masked_suffix(ep):
    """Extract the tail chars from a masked API key in the health response."""
    rrd = ep.get('raw_request_typed_dict', {})
    if rrd:
        hdrs = rrd.get('raw_request_headers', {})
        for h in ('x-goog-api-key', 'Authorization'):
            v = hdrs.get(h, '')
            if v and '****' in v:
                # Format: "AI****OE" → last 2 visible chars = "OE"
                # We use the full suffix after stars: everything after last *
                parts = v.split('*')
                suffix = parts[-1].strip()   # e.g. "OE"
                return suffix
    return ''

def match_key(suffix, keys_dict):
    """Find key_name whose value ends with `suffix`."""
    for kname, kval in keys_dict.items():
        if suffix and kval.endswith(suffix):
            return kname, kval
    return None, None

def make_display(key_val):
    """'AIzaSyAyz...cHwzSpfmOE' → 'AIzaSy...****fmOE'"""
    if len(key_val) < 12:
        return '****'
    return key_val[:6] + '...****' + key_val[-4:]

def is_daily_quota(ep):
    err = ep.get('error', '')
    return ('PerDay' in err
            or 'GenerateRequestsPerDayPerProjectPerModel' in err
            or ('daily' in err.lower() and '429' in err))

# ── Count distinct keys per pool in healthy/unhealthy lists ───────────────────
# We look at ALL model entries (main + alias) to determine if a key is unhealthy,
# then deduplicate by key_name.
def get_model_ids_for_pool(pname):
    return POOLS[pname]['models'] + POOLS[pname]['aliases']

def find_unhealthy_keys_for_pool(pname):
    """Returns dict of {key_name: {key_val, reason_daily, ep}} for unhealthy keys."""
    model_ids = get_model_ids_for_pool(pname)
    keys = pool_keys[pname]
    found = {}
    for ep in unhealthy_eps:
        if ep.get('model', '') not in model_ids:
            continue
        suffix = get_masked_suffix(ep)
        kname, kval = match_key(suffix, keys)
        if kname and kname not in found:
            found[kname] = {
                'key_val': kval,
                'is_daily': is_daily_quota(ep),
            }
    return found  # deduplicated by key_name

def find_healthy_key_names_for_pool(pname):
    model_ids = get_model_ids_for_pool(pname)
    keys = pool_keys[pname]
    found = set()
    for ep in healthy_eps:
        if ep.get('model', '') not in model_ids:
            continue
        suffix = get_masked_suffix(ep)
        kname, _ = match_key(suffix, keys)
        if kname:
            found.add(kname)
    return found

# ── Load existing key-states ───────────────────────────────────────────────────
try:
    states = json.load(open(states_file))
except:
    states = {'schema_version': '1.1', 'pools': {}, 'last_updated': None}

states['schema_version'] = '1.1'

new_alerts   = []
full_exhaust = []

for pname, pdef in POOLS.items():
    total     = pdef['total']
    unhealthy_keys = find_unhealthy_keys_for_pool(pname)
    healthy_key_names = find_healthy_key_names_for_pool(pname)

    # Distinct key counts
    unhealthy_count = len(unhealthy_keys)
    # Healthy = keys that appear healthy AND are NOT in the unhealthy set
    healthy_count   = len(healthy_key_names - set(unhealthy_keys.keys()))
    # If we can't match keys (no suffix available), fall back to total - unhealthy
    if healthy_count == 0 and unhealthy_count < total:
        healthy_count = total - unhealthy_count

    print(f'POOL:{pname}:healthy_keys={healthy_count}:unhealthy_keys={unhealthy_count}:total={total}')

    if pname not in states['pools']:
        states['pools'][pname] = {'total': total, 'resting_keys': [], 'last_checked': None}

    pdata = states['pools'][pname]
    pdata['total']        = total
    pdata['last_checked'] = ts
    pdata['healthy_keys'] = healthy_count
    pdata['unhealthy_keys'] = unhealthy_count

    # Track first-seen for the whole pool
    first_seen_file = os.path.join(first_seen_dir, pname)
    if unhealthy_count == 0:
        if os.path.exists(first_seen_file):
            os.remove(first_seen_file)
    else:
        if not os.path.exists(first_seen_file):
            open(first_seen_file, 'w').write(str(now_epoch))
            print(f'FIRST_SEEN:{pname}')

    first_seen_epoch = 0
    if os.path.exists(first_seen_file):
        try: first_seen_epoch = int(open(first_seen_file).read().strip())
        except: pass
    elapsed = now_epoch - first_seen_epoch if first_seen_epoch > 0 else 0
    is_sustained = (unhealthy_count > 0 and elapsed >= 1200)

    # Remove expired resting entries
    active_resting = [rk for rk in pdata.get('resting_keys', [])
                      if rk.get('recover_epoch', 0) > now_epoch]

    # Add new per-key resting entries
    already_resting_names = {rk['key_name'] for rk in active_resting if 'key_name' in rk}
    newly_resting = []

    for kname, kinfo in unhealthy_keys.items():
        if kname in already_resting_names:
            continue
        if kinfo['is_daily'] or is_sustained:
            entry = {
                'key_name':    kname,
                'key_display': make_display(kinfo['key_val']),
                'reason':      'daily_quota',
                'resting_since': ts,
                'recover_at':  recover_iso,
                'recover_epoch': recover_epoch,
                'confirmed_daily': kinfo['is_daily'],
            }
            active_resting.append(entry)
            newly_resting.append(kname)
            print(f'NEW_REST:{pname}:{kname}')

    pdata['resting_keys'] = active_resting

    # Alert for newly resting keys
    if newly_resting:
        new_alerts.append({
            'pool': pname,
            'keys': newly_resting,
            'count': len(newly_resting),
            'total': total,
            'recover': recover_iso,
        })

    # Full exhaustion check
    if healthy_count == 0 and len(active_resting) > 0:
        full_exhaust.append({'pool': pname, 'total': total})

states['last_updated'] = ts
with open(states_file, 'w') as f:
    json.dump(states, f, indent=2)
print('SAVED:ok')

for a in new_alerts:
    keys_str = ', '.join(a['keys'][:5])  # cap at 5 in message
    extra    = f' (+{len(a["keys"])-5} more)' if len(a["keys"]) > 5 else ''
    print(f'ALERT_REST:{a["pool"]}|{len(a["keys"])}|{a["total"]}|{a["recover"]}|{keys_str}{extra}')

for e in full_exhaust:
    print(f'ALERT_EXHAUSTED:{e["pool"]}|{e["total"]}')
PYEOF
)

# ── Process output lines ──────────────────────────────────────────────────────
while IFS= read -r line; do
  case "$line" in
    PARSE_ERR:*)   log "JSON parse error: ${line#PARSE_ERR:}" ;;
    STATS:*)       log "LiteLLM health: ${line#STATS:}" ;;
    POOL:*)        log "Pool: ${line#POOL:}" ;;
    FIRST_SEEN:*)  log "First seen unhealthy: ${line#FIRST_SEEN:}" ;;
    NEW_REST:*)    log "New resting key: ${line#NEW_REST:}" ;;
    SAVED:*)       log "key-states.json saved" ;;
    ALERT_REST:*)
      IFS='|' read -r pool cnt total recover keys <<< "${line#ALERT_REST:}"
      log "Sending Telegram alert: $pool $cnt/$total resting"
      alert "🔴 <b>API Keys Daily Quota — ${pool}</b>
${cnt} of ${total} key(s) hit daily quota and are now resting.
Affected: <code>${keys}</code>
⏱ Recovery: <b>${recover}</b> (midnight Pacific Time)
Time: ${TS}"
      ;;
    ALERT_EXHAUSTED:*)
      IFS='|' read -r pool total <<< "${line#ALERT_EXHAUSTED:}"
      log "FULL EXHAUSTION: $pool"
      alert "🚨 <b>POOL FULLY EXHAUSTED — ${pool}</b>
All ${total} key(s) are resting. No capacity remaining.
Gateway will attempt Mistral fallback for text requests.
Recovery: <b>${RECOVER_ISO}</b>
Time: ${TS}"
      ;;
  esac
done <<< "$MONITOR_OUTPUT"

rm -f "$HEALTH_TMP" 2>/dev/null || true
log "=== key-monitor done ==="
