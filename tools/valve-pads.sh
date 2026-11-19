#!/usr/bin/env bash
# The Valve (Steam Input) virtual pads on the host: who may open each one, which
# seat udev gave it, and which processes hold it. Read-only.
#   bash valve-pads.sh
set -u
found=0
for dev in /sys/class/input/event*; do
  [ "$(cat "$dev/device/id/vendor" 2>/dev/null)" = 28de ] || continue
  [ -z "$(cat "$dev/device/phys" 2>/dev/null)" ] || continue
  case "$(readlink -f "$dev/device")" in /sys/devices/virtual/*) ;; *) continue ;; esac
  found=1
  node="/dev/input/$(basename "$dev")"
  seat="$(udevadm info -q property -n "$node" 2>/dev/null | sed -n 's/^ID_SEAT=//p')"
  holders="$(for f in /proc/[0-9]*/fd/*; do [ "$(readlink "$f" 2>/dev/null)" = "$node" ] && cat "/proc/$(cut -d/ -f3 <<<"$f")/comm"; done 2>/dev/null | sort -u | tr '\n' ' ')"
  printf '%s | %s | seat=%s | perms=%s | held by: %s\n' "$node" "$(cat "$dev/device/name")" "${seat:-seat0}" "$(stat -c '%A %U:%G' "$node")" "${holders:-nobody}"
done
[ "$found" = 1 ] || echo "no Valve virtual pads right now"
