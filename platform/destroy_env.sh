#!/usr/bin/env bash
# destroy_env.sh — Tear down a sandbox environment cleanly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_ID="${1:-}"

if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env-id>"
  exit 1
fi

STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
LOGS_DIR="$ROOT_DIR/logs/$ENV_ID"
NGINX_CONF="$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"
ARCHIVE_DIR="$ROOT_DIR/logs/archived/$ENV_ID"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "[destroy_env] WARNING: State file not found for $ENV_ID — attempting best-effort cleanup"
  CONTAINER_NAME="app-$ENV_ID"
  NETWORK_NAME="net-$ENV_ID"
else
  CONTAINER_NAME=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('container_name','app-$ENV_ID'))")
  NETWORK_NAME=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('network_name','net-$ENV_ID'))")
  LOG_PID=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('log_shipper_pid',''))" 2>/dev/null || echo "")
fi

echo "[destroy_env] Destroying environment: $ENV_ID"

# --- Kill log shipper ---
if [[ -f "$LOGS_DIR/log_shipper.pid" ]]; then
  LOG_PID=$(cat "$LOGS_DIR/log_shipper.pid")
  if kill -0 "$LOG_PID" 2>/dev/null; then
    kill "$LOG_PID" 2>/dev/null || true
    echo "[destroy_env] Killed log shipper PID $LOG_PID"
  fi
fi

# --- Stop and remove labeled containers ---
CONTAINERS=$(docker ps -a --filter "label=sandbox.env=$ENV_ID" --format "{{.ID}}" 2>/dev/null || true)
if [[ -n "$CONTAINERS" ]]; then
  echo "[destroy_env] Stopping containers: $CONTAINERS"
  echo "$CONTAINERS" | xargs docker stop --time 10 2>/dev/null || true
  echo "$CONTAINERS" | xargs docker rm -f 2>/dev/null || true
fi

# Also try by name in case label is missing
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  docker stop --time 10 "$CONTAINER_NAME" 2>/dev/null || true
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
fi

# --- Disconnect Nginx from network before removing ---
if docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
  docker network disconnect "$NETWORK_NAME" "$NGINX_CONTAINER" 2>/dev/null || true
fi

# --- Remove Docker network ---
if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
  docker network rm "$NETWORK_NAME" 2>/dev/null || true
  echo "[destroy_env] Removed network: $NETWORK_NAME"
fi

# --- Delete Nginx config and reload ---
if [[ -f "$NGINX_CONF" ]]; then
  rm -f "$NGINX_CONF"
  echo "[destroy_env] Removed Nginx config: $NGINX_CONF"
fi

if docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
  docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null || true
  echo "[destroy_env] Reloaded Nginx"
fi

# --- Archive logs ---
if [[ -d "$LOGS_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  cp -r "$LOGS_DIR/." "$ARCHIVE_DIR/" 2>/dev/null || true
  echo "[destroy_env] Archived logs to $ARCHIVE_DIR"
fi

# --- Delete state file ---
rm -f "$STATE_FILE"

# --- Clean up live log dir ---
rm -rf "$LOGS_DIR"

echo "✅ Environment $ENV_ID destroyed successfully."
