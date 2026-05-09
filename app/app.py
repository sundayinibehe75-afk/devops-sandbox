"""
Sandbox demo app — Hello World Flask server with /health endpoint.
This is the app that runs INSIDE each sandbox environment.
"""
import os
import time
from flask import Flask, jsonify

app = Flask(__name__)

ENV_ID   = os.environ.get("ENV_ID", "unknown")
ENV_NAME = os.environ.get("ENV_NAME", "unknown")
START_TIME = time.time()


@app.route("/")
def index():
    return jsonify({
        "message": f"Hello from sandbox environment!",
        "env_id": ENV_ID,
        "env_name": ENV_NAME,
        "uptime_seconds": round(time.time() - START_TIME, 2)
    })


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "env_id": ENV_ID,
        "env_name": ENV_NAME,
        "uptime_seconds": round(time.time() - START_TIME, 2),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    })


@app.route("/info")
def info():
    return jsonify({
        "env_id": ENV_ID,
        "env_name": ENV_NAME,
        "python_version": os.popen("python3 --version").read().strip(),
        "hostname": os.uname().nodename
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port)
