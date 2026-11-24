#!/usr/bin/env bash
# One read-only snapshot of the host for a test record: Hermes, monitors, the
# KDE screen layout, windows, GPU, CPU, memory and the processes that matter.
# Needs no root. Saves to ~/hermes-state/<time>[-label].txt and prints it.
# Usage: bash haven-state.sh [label]     e.g. bash haven-state.sh before
set -u
label="${1:-}"
uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  for socket in "$XDG_RUNTIME_DIR"/wayland-*; do
    case "$socket" in *.lock) continue ;; esac
    [ -S "$socket" ] && WAYLAND_DISPLAY="$(basename "$socket")" && break
  done
fi
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
here="$(cd "$(dirname "$0")" && pwd)"
out_dir="$HOME/hermes-state"
mkdir -p "$out_dir"
out="$out_dir/$(date +%Y%m%d-%H%M%S)${label:+-$label}.txt"

read_file() { [ -r "$1" ] && tr -d '\n' < "$1" || printf '-'; }
# A sensor value divided into its unit, or "-" when the file is missing.
scaled() { local value; value="$(read_file "$1")"; [ "$value" = - ] && printf '-' || printf '%d%s' "$(( value / $2 ))" "$3"; }

snapshot() {
  echo "== Time:    $(date '+%Y-%m-%d %H:%M:%S %Z')   up $(uptime -p | sed 's/^up //')"
  echo "== Hermes:  service $(systemctl --user is-active hermes 2>/dev/null)," \
       "$(journalctl --user -u hermes -n 5000 --no-pager 2>/dev/null | grep -o 'commit: [0-9a-f]\{8\}' | tail -1)"
  journalctl --user -u hermes -n 5000 --no-pager -o cat 2>/dev/null |
    grep -E 'Executing: |Session resuming|Session ended|CLIENT (CONNECTED|DISCONNECTED)|Positioned |Scaling ' |
    tail -4 | sed 's/^/   last: /'

  echo "== Monitors (kernel): connector status enabled dpms"
  for connector in /sys/class/drm/card*-*; do
    [ -r "$connector/status" ] || continue
    status="$(read_file "$connector/status")"
    case "$connector" in *Writeback*) continue ;; esac
    [ "$status" = connected ] || continue
    printf '   %-22s %-10s %-9s %s\n' "$(basename "$connector")" "$status" \
      "$(read_file "$connector/enabled")" "$(read_file "$connector/dpms")"
  done

  echo "== KDE layout (WAYLAND_DISPLAY=$WAYLAND_DISPLAY):"
  if command -v kscreen-doctor >/dev/null && command -v jq >/dev/null; then
    kscreen-doctor -j 2>/dev/null | jq -r '.outputs[] | select(.connected) |
      "   \(.name) enabled=\(.enabled) priority=\(.priority) pos=\(.pos.x),\(.pos.y) size=\(.size.width)x\(.size.height) scale=\(.scale) replica-of=\(.replicationSource)"' ||
      echo "   (kscreen-doctor gave no layout)"
  else
    echo "   (kscreen-doctor or jq missing)"
  fi

  echo "== Windows (bottom to top):"
  if [ -r "$here/kwin-windows.sh" ]; then
    bash "$here/kwin-windows.sh" 2>/dev/null | sed 's/^/   /'
  else
    echo "   (kwin-windows.sh not next to this script)"
  fi

  for card in /sys/class/drm/card[0-9]; do
    device="$card/device"
    [ "$(read_file "$device/vendor")" = 0x1002 ] || continue
    hwmon="$(ls -d "$device"/hwmon/hwmon* 2>/dev/null | head -1)"
    sclk="$(grep '\*' "$device/pp_dpm_sclk" 2>/dev/null | awk '{print $2}')"
    mclk="$(grep '\*' "$device/pp_dpm_mclk" 2>/dev/null | awk '{print $2}')"
    power_file="$hwmon/power1_average"
    [ -r "$power_file" ] || power_file="$hwmon/power1_input"
    echo "== GPU $(basename "$card") ($(basename "$(readlink -f "$device")")):" \
         "busy $(read_file "$device/gpu_busy_percent")%," \
         "level $(read_file "$device/power_dpm_force_performance_level")," \
         "state $(read_file "$device/power_state")," \
         "sclk ${sclk:--} mclk ${mclk:--}"
    echo "   VRAM $(scaled "$device/mem_info_vram_used" 1048576 '')/$(scaled "$device/mem_info_vram_total" 1048576 ' MiB')," \
         "power $(scaled "$power_file" 1000000 ' W')," \
         "edge $(scaled "$hwmon/temp1_input" 1000 C) junction $(scaled "$hwmon/temp2_input" 1000 C)" \
         "mem $(scaled "$hwmon/temp3_input" 1000 C), fan $(read_file "$hwmon/fan1_input") rpm"
  done

  cpu_temp="-"
  for hwmon in /sys/class/hwmon/hwmon*; do
    case "$(read_file "$hwmon/name")" in
      k10temp|coretemp|zenpower) cpu_temp="$(scaled "$hwmon/temp1_input" 1000 C)"; break ;;
    esac
  done
  echo "== CPU:     $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
  echo "   load $(cut -d' ' -f1-3 /proc/loadavg), governor $(read_file /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)," \
       "avg $(awk '/cpu MHz/ {s+=$4; n++} END {if (n) printf "%d", s/n}' /proc/cpuinfo) MHz, temp $cpu_temp"
  echo "== Memory:  $(free -m | awk '/^Mem:/ {printf "%d/%d MiB used, %d MiB available", $3, $2, $7}')"

  echo "== Processes:"
  echo "   hermes:          $(pgrep -x hermes | tr '\n' ' ')"
  echo "   steam client:    $(pgrep -x steam | tr '\n' ' ')  (steamwebhelper: $(pgrep -c steamwebhelpe))"
  echo "   gamescope:       $(pgrep -x gamescope | tr '\n' ' ')"
  echo "   kwin_wayland:    $(pgrep -x kwin_wayland | tr '\n' ' ')  (more than one = isolated sessions)"
  echo "== Hermes-KMS: module $(read_file /sys/module/hermes_kms/version)"
  for connector in /sys/class/drm/card*-Virtual-*; do
    [ -r "$connector/status" ] || continue
    printf '   %-22s %-12s %s\n' "$(basename "$connector")" "$(read_file "$connector/status")" "$(read_file "$connector/enabled")"
  done
}

snapshot 2>&1 | tee "$out"
echo "(saved to $out)"
