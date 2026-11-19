#!/usr/bin/env bash
# One reading of what a running stream depends on, for scheduling during a stream:
#   systemd-run --user --on-active=180 --unit=chk1 sh -c 'bash /tmp/stream-check.sh > /tmp/chk1.txt 2>&1'
# Windows and focus, where audio goes, and the gamepads Hermes made.
set -u
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
here="$(dirname "$0")"
echo "===== $(date '+%H:%M:%S') windows (ACTIVE = has focus)"
bash "$here/kwin-windows.sh"
echo "===== default sink"
pactl get-default-sink
echo "===== sinks"
pactl list short sinks | cut -f2,5
echo "===== playing streams: application -> sink"
pactl -f json list sink-inputs 2>/dev/null | python3 -c '
import json,sys,subprocess
sinks={l.split("\t")[0]:l.split("\t")[1] for l in subprocess.run(["pactl","list","short","sinks"],capture_output=True,text=True).stdout.splitlines()}
for s in json.load(sys.stdin):
    p=s.get("properties",{})
    print(p.get("application.name","?"),"|",p.get("application.process.binary","?"),"->",sinks.get(str(s.get("sink")),s.get("sink")),"| corked" if s.get("corked") else "")
'
echo "===== gamepads (name, handlers)"
grep -B1 -A5 -iE 'Name=.*(xbox|x-box|gamepad|controller|steam|valve|dualsense|hermes)' /proc/bus/input/devices | grep -E 'Name=|Handlers=' | paste - - | sed 's/N: //;s/H: //'
