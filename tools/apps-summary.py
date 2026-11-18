#!/usr/bin/env python3
"""Print each Hermes application entry with the fields that decide how it runs.
Usage: python3 -I apps-summary.py [~/.config/hermes/apps.json] [name filter]"""
import json, os, sys
path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.config/hermes/apps.json")
needle = (sys.argv[2] if len(sys.argv) > 2 else "").lower()
apps = json.load(open(path)).get("apps", [])
for app in apps:
    if needle and needle not in app.get("name", "").lower():
        continue
    print("== " + app.get("name", "?"))
    for key, value in app.items():
        if key in ("name", "image-path", "uuid"):
            continue
        print(f"   {key}: {json.dumps(value)[:200]}")
