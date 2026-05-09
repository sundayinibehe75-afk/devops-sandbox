#!/usr/bin/env python3
"""
Control API — Flask wrapper around sandbox platform scripts.
Endpoints:
  POST   /envs              → create env
  GET    /envs              → list active envs + TTL remaining
  DELETE /envs/:id          → destroy env
  GET    /envs/:id/logs     → last 100 lines of app.log
  GET    /envs/:id/health   → last 10 health check results
  POST   /envs/:id/outage   → trigger simulation
"""

import json
import os
import subprocess
import time
from pathlib import Path

from flask import Flask, jsonify, request, abort

app = Flask(__name__)

ROOT_DIR = Path(__file__).resolve().parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
PLATFORM_DIR = ROOT_DIR / "platform"


def load_state(env_id: str) -> dict:
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        abort(404, description=f"Environment {env_id} not found")
    with open(state_file) as f:
        return json.load(f)


def list_envs() -> list:
    envs = []
    if not ENVS_DIR.exists():
        return envs
    for f in ENVS_DIR.glob("*.json"):
        try:
            with open(f) as fh:
                d = json.load(fh)
            now = int(time.time())
            expires_at = d.get("created_epoch", 0) + d.get("ttl", 1800)
            d["ttl_remaining"] = max(0, expires_at - now)
            d["expires_at"] = expires_at
            envs.append(d)
        except Exception:
            pass
    return envs


# ── POST /envs ──────────────────────────────────────────────────────────────
@app.route("/envs", methods=["POST"])
def create_env():
    body = request.get_json(silent=True) or {}
    name = body.get("name", "").strip()
    ttl = int(body.get("ttl", 1800))

    if not name:
        abort(400, description="'name' is required")
    if ttl < 60 or ttl > 86400:
        abort(400, description="'ttl' must be between 60 and 86400 seconds")

    script = PLATFORM_DIR / "create_env.sh"
    result = subprocess.run(
        ["bash", str(script), name, str(ttl)],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip()}), 500

    # Extract env ID from output
    env_id = None
    for line in result.stdout.splitlines():
        if "ID:" in line:
            env_id = line.split("ID:")[-1].strip()
            break

    return jsonify({
        "message": "Environment created",
        "env_id": env_id,
        "output": result.stdout.strip()
    }), 201


# ── GET /envs ────────────────────────────────────────────────────────────────
@app.route("/envs", methods=["GET"])
def get_envs():
    envs = list_envs()
    return jsonify({"environments": envs, "count": len(envs)})


# ── DELETE /envs/:id ─────────────────────────────────────────────────────────
@app.route("/envs/<env_id>", methods=["DELETE"])
def destroy_env(env_id):
    # Validate env exists
    load_state(env_id)

    script = PLATFORM_DIR / "destroy_env.sh"
    result = subprocess.run(
        ["bash", str(script), env_id],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip()}), 500

    return jsonify({"message": f"Environment {env_id} destroyed", "output": result.stdout.strip()})


# ── GET /envs/:id/logs ───────────────────────────────────────────────────────
@app.route("/envs/<env_id>/logs", methods=["GET"])
def get_logs(env_id):
    load_state(env_id)
    log_file = LOGS_DIR / env_id / "app.log"

    if not log_file.exists():
        return jsonify({"env_id": env_id, "lines": [], "message": "No logs yet"})

    with open(log_file) as f:
        lines = f.readlines()

    last_100 = [l.rstrip() for l in lines[-100:]]
    return jsonify({"env_id": env_id, "lines": last_100, "total_lines": len(lines)})


# ── GET /envs/:id/health ─────────────────────────────────────────────────────
@app.route("/envs/<env_id>/health", methods=["GET"])
def get_health(env_id):
    load_state(env_id)
    health_file = LOGS_DIR / env_id / "health.log"

    if not health_file.exists():
        return jsonify({"env_id": env_id, "checks": [], "message": "No health data yet"})

    with open(health_file) as f:
        lines = f.readlines()

    last_10 = [l.rstrip() for l in lines[-10:]]
    return jsonify({"env_id": env_id, "checks": last_10})


# ── POST /envs/:id/outage ────────────────────────────────────────────────────
@app.route("/envs/<env_id>/outage", methods=["POST"])
def trigger_outage(env_id):
    load_state(env_id)
    body = request.get_json(silent=True) or {}
    mode = body.get("mode", "").strip()

    valid_modes = {"crash", "pause", "network", "recover", "stress"}
    if mode not in valid_modes:
        abort(400, description=f"'mode' must be one of: {', '.join(valid_modes)}")

    script = PLATFORM_DIR / "simulate_outage.sh"
    result = subprocess.run(
        ["bash", str(script), "--env", env_id, "--mode", mode],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip()}), 500

    return jsonify({
        "env_id": env_id,
        "mode": mode,
        "message": f"Outage simulation '{mode}' triggered",
        "output": result.stdout.strip()
    })


# ── Health check for the API itself ─────────────────────────────────────────
@app.route("/health", methods=["GET"])
def api_health():
    return jsonify({"status": "ok", "service": "sandbox-api"})


@app.errorhandler(400)
@app.errorhandler(404)
@app.errorhandler(500)
def handle_error(e):
    return jsonify({"error": str(e.description)}), e.code


if __name__ == "__main__":
    port = int(os.environ.get("API_PORT", 8080))
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    app.run(host="0.0.0.0", port=port, debug=debug)
