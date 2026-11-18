#!/usr/bin/env bash
# For each running Hermes detached desktop: the input devices tagged for it on
# the host, what its private /dev holds, and which of its processes have input
# devices open. Run while a detached stream (or its kept desktop) is alive.
set -u
uid="$(id -u)"
found=0
for flag in /run/user/"$uid"/hermes/isolated/hermes-detached-*; do
  [ -f "$flag" ] || continue
  found=1
  tag="${flag##*/}"
  read -r ns hermes < "$flag"
  echo "== $tag (mount namespace $ns, Hermes pid $hermes)"
  echo "-- host input devices tagged for it:"
  for p in /sys/class/input/input*/phys; do
    [ "$(cat "$p" 2>/dev/null)" = "$tag" ] || continue
    d="${p%/phys}"
    echo "   $(cat "$d/name"): $(ls "$d" | grep -E '^(event|js)' | tr '\n' ' ')"
  done
  echo "-- host hidraw devices tagged for it:"
  for h in /sys/class/hidraw/hidraw*; do
    grep -q "HID_PHYS=$tag" "$h/device/uevent" 2>/dev/null && echo "   ${h##*/}: $(grep HID_NAME "$h/device/uevent")"
  done
  pid=""
  for d in /proc/[0-9]*; do
    [ "$(readlink "$d/ns/mnt" 2>/dev/null)" = "$ns" ] && { pid="${d#/proc/}"; break; }
  done
  if [ -z "$pid" ]; then
    echo "-- no process left in that namespace"
    continue
  fi
  # /proc/<pid>/root is that process's view of the filesystem, its private
  # /dev included; readable for the user's own processes, so no root needed.
  echo "-- inside the desktop (seen through pid $pid):"
  ls -l "/proc/$pid/root/dev/input/" 2>&1 | sed 's/^/   /'
  ls -l /proc/"$pid"/root/dev/hidraw* /proc/"$pid"/root/dev/uinput 2>&1 | sed "s|/proc/$pid/root||; s/^/   /"
  echo "-- its processes holding input devices:"
  for d in /proc/[0-9]*; do
    [ "$(readlink "$d/ns/mnt" 2>/dev/null)" = "$ns" ] || continue
    for f in "$d"/fd/*; do
      l="$(readlink "$f" 2>/dev/null)"
      case "$l" in /dev/input/*|/dev/hidraw*|/dev/uinput) echo "$(cat "$d/comm" 2>/dev/null) -> $l";; esac
    done
  done | sort | uniq -c | sed 's/^/   /'
done
[ "$found" = 1 ] || echo "no Hermes detached desktop is running"
