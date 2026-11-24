#!/usr/bin/env bash
# Record everything a Hermes test depends on, for every test.
#   bash test-recorder.sh start [minutes]   (default 15; runs in the background)
#   bash test-recorder.sh stop              (stops it and prints what happened)
# - a full host snapshot (haven-state.sh) at start and at stop;
# - every second: the screen layout (position, size, scale, replica) and each
#   connector's status, enabled state and DPMS, written when they change;
# - every 20 s: screens and priorities, lock state, windows and focus, audio
#   routing, gamepads and who holds them, Steam/Gamescope/game processes,
#   network rate and GPU load and power;
# - at stop, one timeline in time order of Hermes' key log lines, kernel
#   display messages, monitor changes and layout changes, plus the Gamescope
#   launcher's log for the test.
set -u
dir="$HOME/hermes-tests/current"
uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
here="$(cd "$(dirname "$0")" && pwd)"

desktop_env() {
  local pid
  pid="$(pgrep -xo plasmashell)" || return
  tr '\0' '\n' < "/proc/$pid/environ" | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XAUTHORITY)='
}

stamp() { date '+%Y-%m-%dT%H:%M:%S.%6N%:z'; }

# Screen layout and connectors in one line each, for the 1 s change log.
layout() {
  env $(desktop_env) kscreen-doctor -j 2>/dev/null | jq -r '.outputs[] | select(.connected) |
    "layout \(.name) enabled=\(.enabled) pos=\(.pos.x),\(.pos.y) size=\(.size.width)x\(.size.height) scale=\(.scale) replica-of=\(.replicationSource) priority=\(.priority)"' 2>/dev/null
  for c in /sys/class/drm/card*-*; do
    case "$c" in *Writeback*) continue ;; esac
    [ -r "$c/status" ] || continue
    echo "connector $(basename "$c") $(cat "$c/status") $(cat "$c/enabled" 2>/dev/null) dpms=$(cat "$c/dpms" 2>/dev/null)"
  done
}

gpu() {
  for d in /sys/class/drm/card[0-9]/device; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x1002 ] || continue
    [ "$(cat "$d/mem_info_vram_total" 2>/dev/null || echo 0)" -gt 1073741824 ] || continue
    h="$(ls -d "$d"/hwmon/hwmon* 2>/dev/null | head -1)"
    p="$(cat "$h/power1_average" 2>/dev/null || cat "$h/power1_input" 2>/dev/null || echo 0)"
    echo "busy $(cat "$d/gpu_busy_percent" 2>/dev/null)% power $(( p / 1000000 ))W sclk $(grep '\*' "$d/pp_dpm_sclk" 2>/dev/null | awk '{print $2}') edge $(( $(cat "$h/temp1_input" 2>/dev/null || echo 0) / 1000 ))C"
  done
}

reading() {
  echo "## screens"
  env $(desktop_env) kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' |
    awk '/^Output:/{name=$3; en="?"} /^[[:space:]]*(enabled|disabled)[[:space:]]*$/{en=$1} /priority/{print name, en, "priority", $2}' | sort
  echo "## lock"
  for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
    t="$(loginctl show-session "$s" -p Type --value)"
    [ "$t" = wayland ] || [ "$t" = x11 ] || continue
    echo "session $s locked=$(loginctl show-session "$s" -p LockedHint --value)"
  done
  echo "## windows (ACTIVE = focus)"
  bash "$here/kwin-windows.sh" 2>/dev/null | cut -c1-110
  echo "## audio"
  echo "default sink: $(pactl get-default-sink 2>/dev/null)"
  pactl -f json list sink-inputs 2>/dev/null | python3 -c '
import json,sys,subprocess
sinks={l.split("\t")[0]:l.split("\t")[1] for l in subprocess.run(["pactl","list","short","sinks"],capture_output=True,text=True).stdout.splitlines()}
for s in json.load(sys.stdin):
    p=s.get("properties",{})
    print("stream:",p.get("application.name","?"),"->",sinks.get(str(s.get("sink")),s.get("sink")),"(corked)" if s.get("corked") else "")
' 2>/dev/null
  echo "## gamepads -> held by"
  awk -v RS= '/Name=.*([Xx]box|X-Box|[Gg]amepad|[Cc]ontroller|Steam|Valve|8BitDo|DualSense)/' /proc/bus/input/devices |
  while read -r line; do
    case "$line" in
      N:*) name="${line#N: Name=}" ;;
      H:*) for ev in $(grep -o 'event[0-9]*' <<<"$line"); do
             holders="$(for f in /proc/[0-9]*/fd/*; do [ "$(readlink "$f" 2>/dev/null)" = "/dev/input/$ev" ] && cat "/proc/$(cut -d/ -f3 <<<"$f")/comm"; done 2>/dev/null | sort -u | tr '\n' ' ')"
             echo "$name $ev: ${holders:-nobody}"
           done ;;
    esac
  done
  echo "## processes"
  pgrep -a -f 'steam|gamescope|wine|proton|\.exe' 2>/dev/null | grep -vE 'pgrep|test-recorder|steamwebhelper|reaper|pressure-vessel|srt-|steam-runtime' |
    awk '{c=$2; sub(".*/","",c); print c}' | sort | uniq -c | awk '{print $2" x"$1}'
}

case "${1:-}" in
  start)
    minutes="${2:-15}"
    systemctl --user stop hermes-test-recorder 2>/dev/null
    rm -rf "$dir"; mkdir -p "$dir"
    date +%s > "$dir/start"
    bash "$here/haven-state.sh" before > "$dir/before.txt" 2>&1
    wc -l < "$HOME/.local/state/hermes/gamescope.log" > "$dir/gamescope-start" 2>/dev/null || echo 0 > "$dir/gamescope-start"
    wc -l < "$HOME/.config/hermes/hermes.log" > "$dir/log-start" 2>/dev/null || echo 0 > "$dir/log-start"
    nic="$(ip route show default | awk '{print $5; exit}')"
    echo "$nic" > "$dir/nic"
    systemd-run --user --quiet --unit=hermes-test-recorder-layout bash -c "
      end=\$(( \$(date +%s) + $minutes*60 )); last=
      while [ \$(date +%s) -lt \$end ]; do
        now=\$(bash '$here/test-recorder.sh' layout)
        if [ \"\$now\" != \"\$last\" ]; then
          t=\$(bash '$here/test-recorder.sh' stamp)
          diff <(printf '%s\\n' \"\$last\") <(printf '%s\\n' \"\$now\") | sed -n 's/^> //p; s/^< \\(..*\\)/gone: \\1/p' | sed \"s|^|\$t |\" >> '$dir/layout.txt'
          last=\$now
        fi
        sleep 1
      done"
    systemd-run --user --quiet --unit=hermes-test-recorder bash -c "
      end=\$(( \$(date +%s) + $minutes*60 ))
      prev=\$(cat /sys/class/net/$nic/statistics/tx_bytes); prev_t=\$(date +%s)
      while [ \$(date +%s) -lt \$end ]; do
        now=\$(cat /sys/class/net/$nic/statistics/tx_bytes); now_t=\$(date +%s)
        span=\$(( now_t > prev_t ? now_t - prev_t : 1 ))
        { echo \"===== \$(date +%H:%M:%S)\"; echo \"## network: \$(( (now-prev)*8/span/1000000 )) Mbps sent, gpu \$(bash '$here/test-recorder.sh' gpu)\"; bash '$here/test-recorder.sh' reading; } >> '$dir/readings.txt' 2>&1
        prev=\$now; prev_t=\$now_t
        sleep 20
      done"
    echo "recording for $minutes min (stop early with: bash $here/test-recorder.sh stop)"
    ;;
  reading) reading ;;
  layout) layout ;;
  gpu) gpu ;;
  stamp) stamp ;;
  stop)
    systemctl --user stop hermes-test-recorder hermes-test-recorder-layout 2>/dev/null
    [ -f "$dir/readings.txt" ] || { echo "no recording"; exit 1; }
    started="$(cat "$dir/start" 2>/dev/null || echo 0)"
    echo "=== recording started $(date -d "@$started" '+%Y-%m-%d %H:%M:%S')"
    if [ $(( $(date +%s) - started )) -gt 1200 ]; then
      echo "!!! this recording is old: 'start' was not run before this test, so the readings below are from an earlier test"
    fi
    out="$HOME/hermes-tests/$(date +%Y%m%d-%H%M%S)"
    bash "$here/haven-state.sh" after > "$dir/after.txt" 2>&1
    cp -r "$dir" "$out"
    tail -n +"$(cat "$dir/log-start")" "$HOME/.config/hermes/hermes.log" > "$out/hermes.log" 2>/dev/null
    tail -n +"$(( $(cat "$dir/gamescope-start") + 1 ))" "$HOME/.local/state/hermes/gamescope.log" > "$out/gamescope.log" 2>/dev/null
    since="@$started"
    {
      journalctl --user -u hermes --since "$since" -o short-iso-precise --no-pager -q 2>/dev/null |
        grep -E 'Positioned|Scaling|Executing|Session (started|resuming|pausing|ended)|CLIENT|Virtual display (created|removed)|Connected HERMES|Removing virtual|IsolatedSession|Application windows go|Inhibited|wake|Error|Warning' |
        sed -E 's/^([^ ]+) [^ ]+ [^:]+: \[[^]]+\]: /\1 hermes /'
      journalctl -k --since "$since" -o short-iso-precise --no-pager -q 2>/dev/null |
        grep -iE 'drm|dpcd|DP-[0-9]|HDMI|link|hermes_kms|amdgpu' | sed -E 's/^([^ ]+) [^ ]+ kernel: /\1 kernel /'
      journalctl --user -t hermes-monitor-watch --since "$since" -o short-iso-precise --no-pager -q 2>/dev/null |
        sed -E 's/^([^ ]+) [^ ]+ [^:]+: /\1 monitor /'
      sed 's/^\([^ ]*\) /\1 /' "$out/layout.txt" 2>/dev/null
    } | sort > "$out/timeline.txt"
    echo "=== what changed (full data: $out)"
    python3 - "$out/readings.txt" <<'PY'
import sys,re
blocks=open(sys.argv[1]).read().split("===== ")[1:]
last={}
for b in blocks:
    lines=b.strip().split("\n"); t=lines[0]; sec=None; cur={}
    for l in lines[1:]:
        if l.startswith("## network:"): cur["network"]=[l[3:]]; continue
        if l.startswith("## "): sec=l[3:]; cur[sec]=[]; continue
        if sec: cur[sec].append(l)
    changed=[k for k in cur if k!="network" and cur[k]!=last.get(k)]
    if changed or not last:
        print("--", t, "|", cur.get("network",[""])[0])
        for k in (cur if not last else changed):
            if k=="network": continue
            print("  ["+k+"]"); [print("   ",x) for x in cur[k]]
    last=cur
PY
    echo "=== timeline (Hermes, kernel display, monitors, layout; full: $out/timeline.txt)"
    sed -E 's/^[0-9-]+T([0-9:.]{12})[0-9]*[^ ]* /\1 /' "$out/timeline.txt" | cut -c1-170 | tail -80
    echo "=== Gamescope launcher log during the test"
    tail -20 "$out/gamescope.log" 2>/dev/null
    echo "=== host before and after: $out/before.txt $out/after.txt"
    echo "=== Hermes log: sessions, audio, gamepads, displays, warnings and errors"
    grep -E "Session (started|resuming|pausing|ended)|CLIENT|Selected audio sink|default sink|Gamepad|Positioned|Removing virtual|Virtual Display removed|Executing|Spawning|Stopping|\[Gamescope\]|Warning|Error|lost .* video packets|went silent" "$out/hermes.log" |
      sed -E 's/^\[[0-9-]+ ([0-9:]+)\.[0-9]+\]: /\1 /' | cut -c1-150 | awk '!seen[$0]++' | tail -60
    ;;
  *) echo "usage: $0 start [minutes] | stop"; exit 2 ;;
esac
