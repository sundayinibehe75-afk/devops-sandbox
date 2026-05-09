# DevOps Sandbox Platform — Makefile
# Usage: make <target> [ENV=env-id] [MODE=crash] [NAME=myapp] [TTL=600]

SHELL := /bin/bash
ROOT_DIR := $(shell pwd)
PLATFORM := $(ROOT_DIR)/platform
COMPOSE  := docker compose

.PHONY: up down build create destroy logs health simulate clean status help

## ── Platform lifecycle ──────────────────────────────────────────────────────

up: build          ## Start Nginx, daemon, API, and monitor
	@echo "🚀 Starting sandbox platform..."
	@cp -n .env.example .env 2>/dev/null || true
	$(COMPOSE) up -d
	@echo ""
	@echo "✅ Platform is up!"
	@echo "   API:   http://localhost:$$(grep API_PORT .env | cut -d= -f2 || echo 8080)"
	@echo "   Nginx: http://localhost:$$(grep NGINX_PORT .env | cut -d= -f2 || echo 80)"
	@echo ""
	@echo "Run 'make create' to spin up your first environment."

build:             ## Build Docker images
	@echo "🔨 Building images..."
	docker build -t sandbox-app:latest -f Dockerfile.app .
	$(COMPOSE) build

down:              ## Stop everything and destroy all environments
	@echo "🛑 Tearing down platform..."
	@for f in envs/*.json; do \
	  [ -f "$$f" ] || continue; \
	  ENV_ID=$$(python3 -c "import json; print(json.load(open('$$f'))['id'])" 2>/dev/null); \
	  [ -n "$$ENV_ID" ] && bash $(PLATFORM)/destroy_env.sh "$$ENV_ID" || true; \
	done
	$(COMPOSE) down --remove-orphans
	@echo "✅ Platform stopped."

## ── Environment management ──────────────────────────────────────────────────

create:            ## Create a new environment (prompts for name + TTL)
	@read -p "Environment name: " NAME; \
	 read -p "TTL in seconds [1800]: " TTL; \
	 TTL=$${TTL:-1800}; \
	 bash $(PLATFORM)/create_env.sh "$$NAME" "$$TTL"

destroy:           ## Destroy a specific environment  (ENV=env-id)
ifndef ENV
	$(error ENV is required. Usage: make destroy ENV=env-abc123)
endif
	bash $(PLATFORM)/destroy_env.sh $(ENV)

## ── Observability ───────────────────────────────────────────────────────────

logs:              ## Tail app logs for an environment  (ENV=env-id)
ifndef ENV
	$(error ENV is required. Usage: make logs ENV=env-abc123)
endif
	@LOG_FILE="logs/$(ENV)/app.log"; \
	 if [ -f "$$LOG_FILE" ]; then \
	   tail -f "$$LOG_FILE"; \
	 else \
	   echo "No log file found at $$LOG_FILE"; exit 1; \
	 fi

health:            ## Show health status of all active environments
	@echo "── Environment Health Status ──────────────────────────────"
	@if [ -z "$$(ls envs/*.json 2>/dev/null)" ]; then \
	  echo "  No active environments."; \
	else \
	  for f in envs/*.json; do \
	    [ -f "$$f" ] || continue; \
	    python3 -c " \
import json, time; \
d=json.load(open('$$f')); \
now=int(time.time()); \
exp=d.get('created_epoch',0)+d.get('ttl',1800); \
rem=max(0,exp-now); \
print(f\"  {d['id']:40s}  status={d.get('status','?'):12s}  ttl_remaining={rem}s\") \
    "; \
	  done; \
	fi
	@echo "──────────────────────────────────────────────────────────"

status:            ## Alias for health
	@$(MAKE) health

## ── Chaos engineering ───────────────────────────────────────────────────────

simulate:          ## Run outage simulation  (ENV=env-id MODE=crash|pause|network|recover|stress)
ifndef ENV
	$(error ENV is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
ifndef MODE
	$(error MODE is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
	bash $(PLATFORM)/simulate_outage.sh --env $(ENV) --mode $(MODE)

## ── Maintenance ─────────────────────────────────────────────────────────────

clean:             ## Wipe all state, logs, and archives (keeps platform running)
	@echo "⚠️  This will delete all state files, logs, and archives."
	@read -p "Are you sure? [y/N]: " CONFIRM; \
	 [ "$$CONFIRM" = "y" ] || { echo "Aborted."; exit 0; }; \
	 rm -rf envs/*.json logs/*/  logs/archived/ logs/cleanup.log; \
	 rm -f nginx/conf.d/*.conf; \
	 echo "✅ Cleaned."

## ── Help ────────────────────────────────────────────────────────────────────

help:              ## Show this help message
	@echo ""
	@echo "DevOps Sandbox Platform"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

.DEFAULT_GOAL := help
