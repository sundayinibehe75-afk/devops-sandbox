#!/usr/bin/env bash
# cleanup_daemon.sh — Auto-destroy expired environments every 60 seconds
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENVS_DIR="$ROOT_DIR/envs"
LOG_FILE="$ROOT_DIR/logs/cleanup.log"
DESTROY_SCRIPT="$SCRIPT_DIR/destroy_env.sh"

mkdir -p "$ROOT_DIR/logs"

log() {
  local msg
  msg="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [cleanup_daemon] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

log "Cleanup daemon started (PID=$$)"

while true; do
  NOW=$(date +%s)

  if [[ -d "$ENVS_DIR" ]]; then
    for STATE_FILE in "$ENVS_DIR"/*.json; do
      [[ -f "$STATE_FILE" ]] || continue

      ENV_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('id',''))" 2>/dev/null || true)
      CREATED_EPOCH=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('created_epoch',0))" 2>/dev/null || echo "0")
      TTL=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('ttl',1800))" 2>/dev/null || echo "1800")
      STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','running'))" 2>/dev/null || echo "running")

      if [[ -z "$ENV_ID" ]]; then
        log "WARNING: Could not parse state file $STATE_FILE — skipping"
        continue
      fi

      EXPIRES_AT=$((CREATED_EPOCH + TTL))
      REMAINING=$((EXPIRES_AT - NOW))

      if [[ "$NOW" -ge "$EXPIRES_AT" ]]; then
        log "Environment $ENV_ID has expired (TTL=${TTL}s). Destroying..."
        if bash "$DESTROY_SCRIPT" "$ENV_ID" >> "$LOG_FILE" 2>&1; then
          log "Successfully destroyed expired environment: $ENV_ID"
        else
          log "ERROR: Failed to destroy environment: $ENV_ID"
        fi
      else
        log "Environment $ENV_ID is alive — expires in ${REMAINING}s (status=$STATUS)"
      fi
    done
  fi

  log "Sleeping 60 seconds..."
  sleep 60
done
