# DevOps Sandbox Platform

A self-service platform for spinning up isolated, short-lived environments — deploy apps, simulate outages, monitor health, and auto-destroy on TTL expiry. Think of it as a miniature internal Heroku with a chaos engineering toggle.

---

## Architecture

```
                        ┌─────────────────────────────────────────────────────┐
                        │                  Linux VM (single host)              │
                        │                                                       │
  User / CI             │   ┌──────────────┐     ┌──────────────────────────┐  │
  ──────────────────────┼──▶│  Nginx :80   │────▶│  sandbox env containers  │  │
                        │   │  (reverse    │     │  app-env-xxx  :5000      │  │
  make / curl           │   │   proxy)     │     │  app-env-yyy  :5000      │  │
  ──────────────────────┼──▶│              │     └──────────────────────────┘  │
                        │   └──────────────┘              ▲                    │
                        │                                  │ docker networks    │
                        │   ┌──────────────┐     ┌────────┴─────────────────┐  │
  API clients           │   │  Control API │────▶│  platform scripts        │  │
  ──────────────────────┼──▶│  Flask :8080 │     │  create_env.sh           │  │
                        │   └──────────────┘     │  destroy_env.sh          │  │
                        │                        │  simulate_outage.sh      │  │
                        │   ┌──────────────┐     └──────────────────────────┘  │
                        │   │  Cleanup     │                                    │
                        │   │  Daemon      │  loops every 60s, destroys         │
                        │   │  (bash)      │  expired envs                      │
                        │   └──────────────┘                                    │
                        │                                                       │
                        │   ┌──────────────┐                                    │
                        │   │  Health      │  polls /health every 30s           │
                        │   │  Poller      │  marks env "degraded" after 3      │
                        │   │  (bash)      │  consecutive failures               │
                        │   └──────────────┘                                    │
                        │                                                       │
                        │   envs/*.json  ← runtime state (gitignored)           │
                        │   logs/        ← app + health logs (gitignored)       │
                        │   nginx/conf.d ← auto-generated per-env configs       │
                        └─────────────────────────────────────────────────────┘
```

### Network Approach

Each environment gets its own Docker bridge network (`net-<env-id>`). The Nginx container is dynamically connected to each new network at creation time so it can reach the app container by name. On destroy, Nginx is disconnected and the network is removed. All platform containers share a `sandbox-mgmt` management network.

---

## Prerequisites

- Docker ≥ 24 and Docker Compose v2
- Python 3.11+ (for the API and state management)
- bash, curl, make

```bash
# Verify
docker --version
docker compose version
python3 --version
```

---

## Quick Start — Zero to First Running Environment in 5 Commands

```bash
# 1. Clone the repo
git clone https://github.com/<your-username>/devops-sandbox.git && cd devops-sandbox

# 2. Copy env config
cp .env.example .env

# 3. Build images and start the platform
make up

# 4. Create your first environment
make create
# → enter name: myapp
# → enter TTL: 300

# 5. Check it's alive
curl http://localhost:8080/envs
```

Your environment is now running. Nginx is routing `http://<env-id>.sandbox.local` to it.

---

## Full Demo Walkthrough

### 1. Start the platform

```bash
make up
```

### 2. Create an environment

```bash
make create
# name: demo
# TTL: 600
```

Output:
```
✅ Environment created successfully!
   ID:      env-demo-123456
   URL:     http://env-demo-123456.sandbox.local
   Port:    8342
   TTL:     600s
```

### 3. Check health

```bash
make health
# or via API:
curl http://localhost:8080/envs/env-demo-123456/health
```

### 4. Simulate an outage

```bash
make simulate ENV=env-demo-123456 MODE=crash
```

### 5. Observe degraded status

```bash
# Wait ~90 seconds for health poller to detect 3 failures
make health
# status=degraded
```

### 6. Recover

```bash
make simulate ENV=env-demo-123456 MODE=recover
```

### 7. Watch auto-destroy

```bash
# After TTL expires (600s), the cleanup daemon destroys it automatically
tail -f logs/cleanup.log
```

---

## API Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/envs` | Create environment `{"name":"x","ttl":600}` |
| `GET` | `/envs` | List all active envs with TTL remaining |
| `DELETE` | `/envs/:id` | Destroy environment |
| `GET` | `/envs/:id/logs` | Last 100 lines of app.log |
| `GET` | `/envs/:id/health` | Last 10 health check results |
| `POST` | `/envs/:id/outage` | Trigger simulation `{"mode":"crash"}` |
| `GET` | `/health` | API health check |

### Examples

```bash
# Create
curl -X POST http://localhost:8080/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"myapp","ttl":300}'

# List
curl http://localhost:8080/envs

# Destroy
curl -X DELETE http://localhost:8080/envs/env-myapp-123456

# Trigger outage
curl -X POST http://localhost:8080/envs/env-myapp-123456/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"pause"}'

# Recover
curl -X POST http://localhost:8080/envs/env-myapp-123456/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"recover"}'
```

---

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make up` | Build images and start Nginx, daemon, API, monitor |
| `make down` | Stop everything and destroy all environments |
| `make build` | Build Docker images only |
| `make create` | Create a new environment (interactive) |
| `make destroy ENV=…` | Destroy a specific environment |
| `make logs ENV=…` | Tail app logs for an environment |
| `make health` | Show all environment health statuses |
| `make simulate ENV=… MODE=…` | Run outage simulation |
| `make clean` | Wipe all state, logs, and archives |
| `make status` | Alias for health |

---

## Outage Simulation Modes

| Mode | Effect | Recovery |
|------|--------|----------|
| `crash` | `docker kill` — container stops | `MODE=recover` restarts it |
| `pause` | `docker pause` — container frozen | `MODE=recover` unpauses it |
| `network` | Disconnects container from its network | `MODE=recover` reconnects it |
| `recover` | Restores whatever was broken | — |
| `stress` | Spikes CPU for ~60s | Auto-recovers |

---

## Project Structure

```
devops-sandbox/
├── platform/
│   ├── create_env.sh        # Spin up an isolated environment
│   ├── destroy_env.sh       # Tear down an environment cleanly
│   ├── cleanup_daemon.sh    # Auto-destroy expired environments
│   ├── simulate_outage.sh   # Inject failures (crash/pause/network/stress)
│   └── api.py               # Flask control API
├── nginx/
│   ├── nginx.conf           # Main Nginx config (includes conf.d/)
│   └── conf.d/              # Auto-generated per-env server blocks
├── monitor/
│   └── health_poller.sh     # Polls /health every 30s, marks degraded
├── app/
│   └── app.py               # Demo app (runs inside sandbox containers)
├── logs/                    # gitignored — app + health logs
├── envs/                    # gitignored — runtime state JSON files
├── Makefile
├── docker-compose.yml
├── Dockerfile.api
├── Dockerfile.app
├── requirements.txt
├── .env.example
└── README.md
```

---

## Known Limitations

- **Single VM only** — no clustering or multi-host support. All containers run on one Docker daemon.
- **Port allocation** — host ports for app containers are randomly assigned from 8100–9000. Collisions are possible under heavy load (unlikely in practice).
- **Nginx hostname routing** — environments are routed by `Host` header (`<env-id>.sandbox.local`). You need to add entries to `/etc/hosts` or use a wildcard DNS entry to test from a browser. `curl -H "Host: env-xxx.sandbox.local" http://localhost` works without DNS changes.
- **No TLS** — Nginx runs HTTP only. Add Certbot + Let's Encrypt for HTTPS.
- **Log shipping is Approach A** — `docker logs -f` piped to a file. For production, use Loki or Fluentd (Approach B).
- **No authentication** — the API has no auth layer. Add an API key middleware before exposing publicly.
- **Cleanup daemon uses Python** — the daemon container installs Docker CLI at startup which adds ~30s to first boot. Pre-bake a custom image to eliminate this.

---

## CI/CD

GitHub Actions runs on every push:
1. Shell script linting (shellcheck)
2. Python syntax validation
3. Nginx config validation
4. Docker image builds
5. Smoke test — app container starts and `/health` returns 200
