#!/usr/bin/env bash
# Hermes Detached test harness for HAVEN.
#
#   hermes-test.sh monitor      follow Hermes and the detached desktop until Ctrl+C
#   hermes-test.sh hold         cut the stream while something is held, then check
#   hermes-test.sh controller   check that a controller creates no device
#
# Everything goes to ~/hermes-test-logs/<mode>-<time>.log as well as the screen.
# Only reads state, except "hold", which adds one nftables table of its own for
# a bounded time and always removes it on exit.

set -u

mode=${1:-}
logdir="$HOME/hermes-test-logs"
mkdir -p "$logdir"
log="$logdir/${mode:-none}-$(date +%Y%m%d-%H%M%S).log"
table=hermes_hold_test
follower=

say() { printf '%s  %s\n' "$(date +%T)" "$*" | tee -a "$log"; }

cleanup() {
  [ -n "$follower" ] && kill "$follower" 2>/dev/null
  if [ "$mode" = hold ] && sudo -n nft list table inet "$table" >/dev/null 2>&1; then
    sudo -n nft delete table inet "$table" && say "block removed"
  fi
}
trap cleanup EXIT INT TERM

follow_hermes() {
  journalctl --user -u hermes.service -f -n 0 -o short-iso --no-pager >>"$log" 2>&1 &
  follower=$!
}

snapshot() {
  say "--- $1"
  {
    echo "hermes: $(systemctl --user is-active hermes.service) pid $(systemctl --user show -p MainPID --value hermes.service)"
    echo "detached units:"
    systemctl --user list-units 'hermes-detached-*' --all --no-legend --plain | sed 's/^/  /'
    echo "input devices: $(ls /dev/input | wc -l)"
    ls -1 /dev/input/by-id 2>/dev/null | sed 's/^/  /'
    echo "polkit failures:"
    faillock --user "$USER" | tail -n +3 | sed 's/^/  /'
  } | tee -a "$log"
}

stream_ports() {
  # Hermes streams on UDP base+9 .. base+21; base is "port" in its config.
  local base
  base=$(sed -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' \
    "$HOME/.config/sunshine/sunshine.conf" "$HOME/.config/hermes/hermes.conf" 2>/dev/null | tail -1)
  base=${base:-47989}
  echo "$((base + 9))-$((base + 21))"
}

wait_for_end() {
  # Seconds until Hermes logs the end of a stream, or nothing after $1 seconds.
  local start=$SECONDS
  while [ $((SECONDS - start)) -lt "$1" ]; do
    if grep -q -E 'Session ended|Ping Timeout|CLIENT DISCONNECTED' "$log"; then
      echo $((SECONDS - start))
      return 0
    fi
    sleep 1
  done
  return 1
}

case "$mode" in
  monitor)
    say "monitor: logging to $log, Ctrl+C to stop"
    snapshot "start"
    follow_hermes
    while sleep 30; do snapshot "every 30 s"; done
    ;;

  hold)
    sudo -v || exit 1
    ports=$(stream_ports)
    say "hold test: logging to $log; stream ports udp $ports"
    snapshot "before"
    follow_hermes
    for left in 15 10 5; do
      say "block in $left s: be in Artemis, start holding now"
      sleep 5
    done
    sudo -n nft add table inet "$table"
    sudo -n nft add chain inet "$table" input '{ type filter hook input priority -50; }'
    sudo -n nft add rule inet "$table" input udp dport "$ports" drop
    say "BLOCKED: stream traffic dropped (IPv4 and IPv6). Keep holding."
    if took=$(wait_for_end 40); then
      say "Hermes ended the stream ${took} s after the block, while held"
      result=ended
    else
      say "Hermes did not end the stream within 40 s"
      result=not-ended
    fi
    sleep 3
    sudo -n nft delete table inet "$table" && say "block removed: you can let go and reconnect"
    say "reconnect now; the check runs in 60 s"
    sleep 60
    snapshot "after reconnect"
    say "--- Hermes log during the test"
    grep -E 'Session ended|Ping Timeout|CLIENT DISCONNECTED|streaming session|rror|arning' "$log" | grep -v -- '---' | tail -20
    if [ "$result" = ended ]; then
      say "RESULT: stream ended while held. Now check the pointer: moves freely = PASS"
    else
      say "RESULT: INVALID, the stream was not cut; nothing was tested"
    fi
    ;;

  controller)
    say "controller test: logging to $log"
    snapshot "before"
    follow_hermes
    say "connect the controller (or Artemis's on-screen controller) now, use it for a few seconds, then press Enter here"
    read -r _
    snapshot "after"
    say "--- Hermes log during the test"
    grep -i -E 'gamepad|controller|refus' "$log" | tail -20
    say "PASS = the device list is unchanged and Hermes logged a refusal"
    ;;

  *)
    echo "usage: $0 monitor|hold|controller" >&2
    exit 2
    ;;
esac
