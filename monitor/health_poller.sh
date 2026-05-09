#!/usr/bin/env bash
# health_poller.sh — Poll /health on every active environment every 30 seconds
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
POLL_INTERVAL="${HEALTH_POLL_INTERVAL:-30}"
FAILURE_THRESHOLD=3

declare -A FAILURE_COUNTS

log_health() {
  local env_id="$1"
  local status="$2"
  local latency="$3"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local log_file="$LOGS_DIR/$env_id/health.log"
  mkdir -p "$(dirname "$log_file")"
  echo "$timestamp status=$status latency=${latency}ms" >> "$log_file"
}

update_status() {
  local state_file="$1"
  local new_status="$2"
  python3 - "$state_file" "$new_status" <<'PYEOF'
import json, sys, os
path, status = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    sys.exit(0)
with open(path) as f:
    d = json.load(f)
d['status'] = status
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
os.replace(tmp, path)
PYEOF
}

echo "[health_poller] Started (PID=$$, interval=${POLL_INTERVAL}s)"

while true; do
  if [[ -d "$ENVS_DIR" ]]; then
    for STATE_FILE in "$ENVS_DIR"/*.json; do
      [[ -f "$STATE_FILE" ]] || continue

      ENV_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('id',''))" 2>/dev/null || true)
      HOST_PORT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('host_port',''))" 2>/dev/null || true)
      STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','running'))" 2>/dev/null || echo "running")

      [[ -z "$ENV_ID" || -z "$HOST_PORT" ]] && continue
      [[ "$STATUS" == "destroyed" ]] && continue

      HEALTH_URL="http://localhost:${HOST_PORT}/health"

      START_NS=$(date +%s%N 2>/dev/null || echo "0")
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null || echo "000")
      END_NS=$(date +%s%N 2>/dev/null || echo "0")

      if [[ "$START_NS" != "0" && "$END_NS" != "0" ]]; then
        LATENCY=$(( (END_NS - START_NS) / 1000000 ))
      else
        LATENCY=0
      fi

      log_health "$ENV_ID" "$HTTP_CODE" "$LATENCY"

      if [[ "$HTTP_CODE" == "200" ]]; then
        FAILURE_COUNTS[$ENV_ID]=0
        if [[ "$STATUS" == "degraded" ]]; then
          echo "[health_poller] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $ENV_ID recovered (HTTP 200)"
          update_status "$STATE_FILE" "running"
        fi
      else
        FAILURE_COUNTS[$ENV_ID]=$(( ${FAILURE_COUNTS[$ENV_ID]:-0} + 1 ))
        COUNT=${FAILURE_COUNTS[$ENV_ID]}
        echo "[health_poller] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $ENV_ID health check FAILED (HTTP=$HTTP_CODE, failures=$COUNT)"

        if [[ "$COUNT" -ge "$FAILURE_THRESHOLD" && "$STATUS" != "degraded" ]]; then
          echo "⚠️  WARNING: Environment $ENV_ID is DEGRADED after $COUNT consecutive failures!"
          update_status "$STATE_FILE" "degraded"
        fi
      fi
    done
  fi

  sleep "$POLL_INTERVAL"
done
