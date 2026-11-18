#!/usr/bin/env bash
# Everything about Steam, Hermes' sessions and connected clients at one moment.
# Usage: bash steam-snapshot.sh [label]
set -u
uid="$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$uid/bus}"
echo "##### ${1:-snapshot} at $(date '+%H:%M:%S')"
host_ns="$(readlink /proc/1/ns/mnt 2>/dev/null || readlink /proc/self/ns/mnt)"
hermes="$(pgrep -xo hermes)"
echo "hermes pid $hermes, its mount ns $(readlink /proc/$hermes/ns/mnt 2>/dev/null) (host $host_ns)"
echo "--- Steam processes (pid | ns | cgroup | parent | started):"
for p in $(pgrep -x steam); do
  pp="$(ps -o ppid= -p "$p" | tr -d ' ')"
  echo "  $p | $(readlink /proc/$p/ns/mnt) | $(cut -d: -f3 /proc/$p/cgroup | sed 's|.*/||') | $pp $(ps -o comm= -p "$pp") | $(ps -o lstart= -p "$p")"
done
echo "  steam.pid: $(cat ~/.steam/steam.pid 2>/dev/null)   steamwebhelpers: $(pgrep -c steamwebhelper)"
echo "--- detached desktops:"
systemctl --user list-units --no-legend 'hermes-detached-*' 2>/dev/null | awk '{print "  "$1" "$3" "$4}'
ls /run/user/"$uid"/hermes/isolated/ 2>/dev/null | sed 's/^/  flag: /'
echo "--- connected clients (Hermes TCP peers):"
ss -tnpH state established 2>/dev/null | grep -E 'hermes' | awk '{print "  "$3" <- "$4}' | sort -u
echo "--- Hermes' last session events:"
grep -E 'CLIENT (CONNECTED|DISCONNECTED)|Session (started|resuming|pausing|ended)|active sessions|Spawning|Executing( Undo)? Cmd|Executing:|IsolatedSession\] (Starting|Stopping|Keeping|Shutting)|desktop.s Steam' ~/.config/hermes/hermes.log 2>/dev/null | tail -8 | cut -c1-160 | sed 's/^/  /'
echo "--- windows (class | pid | output):"
bash "$(dirname "$0")/kwin-windows.sh" 2>/dev/null | sed 's/^/  /'
