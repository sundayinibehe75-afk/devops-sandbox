#!/usr/bin/env bash
# create_env.sh — Spin up an isolated sandbox environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_NAME="${1:-}"
TTL="${2:-1800}"  # default 30 minutes

if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <env-name> [ttl-seconds]"
  exit 1
fi

# Generate unique env ID
ENV_ID="env-$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')-$(date +%s | tail -c 6)"
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CREATED_EPOCH=$(date +%s)

NETWORK_NAME="net-$ENV_ID"
CONTAINER_NAME="app-$ENV_ID"
APP_IMAGE="${APP_IMAGE:-sandbox-app:latest}"
HOST_PORT=$(shuf -i 8100-9000 -n 1)

ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs/$ENV_ID"
NGINX_CONF="$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"
STATE_FILE="$ENVS_DIR/$ENV_ID.json"

mkdir -p "$ENVS_DIR" "$LOGS_DIR" "$ROOT_DIR/nginx/conf.d"

echo "[create_env] Creating environment: $ENV_ID (name=$ENV_NAME, ttl=${TTL}s)"

# --- Docker network ---
docker network create "$NETWORK_NAME" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.name=$ENV_NAME"

# --- Connect Nginx container to new network ---
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
if docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
  docker network connect "$NETWORK_NAME" "$NGINX_CONTAINER" 2>/dev/null || true
fi

# --- Start app container ---
docker run -d \
  --name "$CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.name=$ENV_NAME" \
  --label "sandbox.managed=true" \
  -e ENV_ID="$ENV_ID" \
  -e ENV_NAME="$ENV_NAME" \
  -p "${HOST_PORT}:5000" \
  "$APP_IMAGE"

CONTAINER_ID=$(docker inspect --format '{{.Id}}' "$CONTAINER_NAME")

# --- Log shipping (Approach A) ---
mkdir -p "$LOGS_DIR"
nohup docker logs -f "$CONTAINER_NAME" >> "$LOGS_DIR/app.log" 2>&1 &
LOG_PID=$!
echo "$LOG_PID" > "$LOGS_DIR/log_shipper.pid"

# --- Nginx config ---
cat > "$NGINX_CONF" <<NGINXCONF
# Auto-generated for env: $ENV_ID
upstream $ENV_ID {
    server $CONTAINER_NAME:5000;
}

server {
    listen 80;
    server_name $ENV_ID.sandbox.local;

    location / {
        proxy_pass http://$ENV_ID;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Env-ID $ENV_ID;
    }

    location /health {
        proxy_pass http://$ENV_ID/health;
    }
}
NGINXCONF

# Reload Nginx
if docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
  docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null || true
fi

# --- Write state file atomically ---
TEMP_STATE=$(mktemp)
cat > "$TEMP_STATE" <<JSON
{
  "id": "$ENV_ID",
  "name": "$ENV_NAME",
  "created_at": "$CREATED_AT",
  "created_epoch": $CREATED_EPOCH,
  "ttl": $TTL,
  "status": "running",
  "container_name": "$CONTAINER_NAME",
  "container_id": "$CONTAINER_ID",
  "network_name": "$NETWORK_NAME",
  "host_port": $HOST_PORT,
  "log_shipper_pid": $LOG_PID,
  "url": "http://$ENV_ID.sandbox.local"
}
JSON
mv "$TEMP_STATE" "$STATE_FILE"

echo ""
echo "✅ Environment created successfully!"
echo "   ID:      $ENV_ID"
echo "   Name:    $ENV_NAME"
echo "   URL:     http://$ENV_ID.sandbox.local"
echo "   Port:    $HOST_PORT"
echo "   TTL:     ${TTL}s (expires at $(date -u -d "@$((CREATED_EPOCH + TTL))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$((CREATED_EPOCH + TTL))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "in ${TTL}s"))"
echo ""
