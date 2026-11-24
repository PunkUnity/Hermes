#!/usr/bin/env bash
# Log every change of a physical monitor's state to the journal, so a test can
# see when a screen went off, came on, dropped off the cable or came back.
# Nothing on the desktop records this by default: KWin and the kernel don't.
# Reads sysfs every 5 s; no root. Lines are tagged hermes-monitor-watch:
#   journalctl --user -t hermes-monitor-watch
# Usage: bash monitor-watch.sh            run in the foreground
#        bash monitor-watch.sh install    run it as a user service from now on
#        bash monitor-watch.sh remove     stop and remove that service
set -u
drm="${HERMES_DRM_SYSFS:-/sys/class/drm}"
interval="${HERMES_MONITOR_WATCH_INTERVAL:-5}"
unit="$HOME/.config/systemd/user/hermes-monitor-watch.service"

case "${1:-}" in
  install)
    mkdir -p "$(dirname "$unit")"
    cat > "$unit" <<UNIT
[Unit]
Description=Log physical monitor state changes for Hermes tests

[Service]
ExecStart=/usr/bin/env bash $(readlink -f "$0")
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload && systemctl --user enable --now hermes-monitor-watch.service &&
      systemctl --user is-active hermes-monitor-watch.service
    exit
    ;;
  remove)
    systemctl --user disable --now hermes-monitor-watch.service
    rm -f "$unit"
    systemctl --user daemon-reload
    exit
    ;;
esac

read_file() { [ -r "$1" ] && tr -d '\n' < "$1" || printf -- '-'; }

# Physical connectors only: virtual (Hermes-KMS) and writeback ones change with
# every stream and are logged by Hermes itself.
state() {
  for connector in "$drm"/card*-*; do
    case "$connector" in *Virtual*|*Writeback*) continue ;; esac
    [ -r "$connector/status" ] || continue
    printf '%s status=%s enabled=%s dpms=%s\n' "$(basename "$connector")" "$(read_file "$connector/status")" \
      "$(read_file "$connector/enabled")" "$(read_file "$connector/dpms")"
  done
}

log() { printf '%s\n' "$1" | systemd-cat -t hermes-monitor-watch 2>/dev/null || printf '%s %s\n' "$(date '+%F %T')" "$1"; }

declare -A last
first=1
while :; do
  while read -r name rest; do
    [ -n "$name" ] || continue
    if [ "${last[$name]:-}" != "$rest" ]; then
      if [ "$first" = 1 ]; then log "$name $rest (watch started)"; else log "$name $rest (was ${last[$name]:-unseen})"; fi
      last[$name]="$rest"
    fi
  done < <(state)
  first=0
  sleep "$interval"
done
