#!/usr/bin/env python3
"""Print health status of all active environments."""
import json
import time
import glob
import sys

files = sorted(glob.glob("envs/*.json"))
if not files:
    print("  No active environments.")
    sys.exit(0)

for path in files:
    try:
        with open(path) as f:
            d = json.load(f)
        now = int(time.time())
        exp = d.get("created_epoch", 0) + d.get("ttl", 1800)
        rem = max(0, exp - now)
        env_id = d.get("id", "unknown")
        status = d.get("status", "?")
        print(f"  {env_id:45s}  status={status:16s}  ttl_remaining={rem}s")
    except Exception as e:
        print(f"  ERROR reading {path}: {e}")
