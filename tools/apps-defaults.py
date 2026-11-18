#!/usr/bin/env python3
"""Put the Steam Big Picture and Gamescope Steam Session entries back to the
display settings Hermes ships (src_assets/linux/assets/apps.json), keeping
everything else. Backs up apps.json first.

Usage: python3 -I apps-defaults.py [~/.config/hermes/apps.json]"""
import json, os, shutil, sys, time

path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.config/hermes/apps.json")
backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(path, backup)
data = json.load(open(path))

wanted = {
    # Streams the real monitor: Big Picture and its games open there.
    "Steam Big Picture": {"virtual-display": False, "virtual-display-layout": None},
    # A virtual display mirroring the primary monitor, where Gamescope's window opens.
    "Gamescope Steam Session": {"virtual-display": True, "virtual-display-layout": "mirror",
                                "auto-detach": False, "wait-all": True},
}
for app in data.get("apps", []):
    changes = wanted.get(app.get("name"))
    if not changes:
        continue
    for key, value in changes.items():
        before = app.get(key, "(unset)")
        if value is None:
            app.pop(key, None)
        else:
            app[key] = value
        after = app.get(key, "(unset)")
        if before != after:
            print(f"{app['name']}: {key} {before} -> {after}")
    print(f"{app['name']}: unlock-host-session = {app.get('unlock-host-session', False)}, "
          f"stop-detached = {app.get('stop-detached', True)}")

tmp = path + ".tmp"
with open(tmp, "w") as out:
    json.dump(data, out, indent=4)
os.replace(tmp, path)
print(f"saved; backup at {backup}")
