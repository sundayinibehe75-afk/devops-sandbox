#!/usr/bin/env bash
# simulate_outage.sh — Inject failures into a sandbox environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_ID=""
MODE=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)   ENV_ID="$2";  shift 2 ;;
    --mode)  MODE="$2";    shift 2 ;;
    *)       echo "Unknown flag: $1"; exit 1 ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "Usage: $0 --env <env-id> --mode <crash|pause|network|recover|stress>"
  exit 1
fi

# --- Guard: never simulate against platform containers ---
PROTECTED_PATTERNS=("sandbox-nginx" "sandbox-daemon" "sandbox-api" "nginx" "cleanup")
CONTAINER_NAME="app-$ENV_ID"

for pattern in "${PROTECTED_PATTERNS[@]}"; do
  if [[ "$CONTAINER_NAME" == *"$pattern"* ]]; then
    echo "❌ REFUSED: Cannot simulate outage against protected container: $CONTAINER_NAME"
    exit 1
  fi
done

# Verify env exists
STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "❌ Environment $ENV_ID not found"
  exit 1
fi

NETWORK_NAME=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('network_name','net-$ENV_ID'))" 2>/dev/null || echo "net-$ENV_ID")

update_status() {
  local new_status="$1"
  python3 - "$STATE_FILE" "$new_status" <<'PYEOF'
import json, sys
path, status = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d['status'] = status
with open(path + '.tmp', 'w') as f:
    json.dump(d, f, indent=2)
import os
os.replace(path + '.tmp', path)
PYEOF
}

echo "[simulate_outage] ENV=$ENV_ID MODE=$MODE"

case "$MODE" in
  crash)
    echo "💥 Crashing container: $CONTAINER_NAME"
    docker kill "$CONTAINER_NAME"
    update_status "crashed"
    echo "Container killed. Health monitor should detect within 90s."
    ;;

  pause)
    echo "⏸  Pausing container: $CONTAINER_NAME"
    docker pause "$CONTAINER_NAME"
    update_status "paused"
    echo "Container paused. Use --mode recover to unpause."
    ;;

  network)
    echo "🔌 Disconnecting container from network: $NETWORK_NAME"
    docker network disconnect "$NETWORK_NAME" "$CONTAINER_NAME"
    update_status "network-isolated"
    echo "Container network disconnected. Use --mode recover to reconnect."
    ;;

  stress)
    echo "🔥 Stressing container CPU: $CONTAINER_NAME"
    docker exec -d "$CONTAINER_NAME" sh -c \
      "which stress-ng && stress-ng --cpu 2 --timeout 60s || (dd if=/dev/urandom of=/dev/null bs=1M &)" 2>/dev/null || \
      docker exec -d "$CONTAINER_NAME" sh -c "yes > /dev/null &"
    update_status "stressed"
    echo "CPU stress started for ~60s."
    ;;

  recover)
    CURRENT_STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','running'))" 2>/dev/null || echo "unknown")
    echo "🔧 Recovering environment $ENV_ID (current status: $CURRENT_STATUS)"

    case "$CURRENT_STATUS" in
      paused)
        docker unpause "$CONTAINER_NAME" 2>/dev/null || true
        echo "Container unpaused."
        ;;
      network-isolated)
        docker network connect "$NETWORK_NAME" "$CONTAINER_NAME" 2>/dev/null || true
        echo "Container reconnected to network."
        ;;
      crashed|degraded)
        docker start "$CONTAINER_NAME" 2>/dev/null || true
        echo "Container restarted."
        ;;
      *)
        echo "Attempting generic recovery (restart)..."
        docker restart "$CONTAINER_NAME" 2>/dev/null || true
        ;;
    esac

    update_status "running"
    echo "✅ Environment $ENV_ID recovered."
    ;;

  *)
    echo "❌ Unknown mode: $MODE. Valid: crash, pause, network, recover, stress"
    exit 1
    ;;
esac
