#!/usr/bin/env bash
# Unattended experiment: which way of waking DP-2 from deep sleep is clean?
# Run as root (systemd-run). Nobody needs to watch it. Results: /home/kyprian/wake-lab.log
user=kyprian
uid=$(id -u "$user")
conn=$(ls -d /sys/class/drm/card*-DP-2 | head -n 1)
aux=/dev/$(basename "$(ls -d "$conn"/drm_dp_aux* | head -n 1)")
bus=$(basename "$(readlink "$conn/ddc")" | sed "s/i2c-//")
log=/home/$user/wake-lab.log
asleep_minutes=${ASLEEP_MINUTES:-16}

kdoctor() { runuser -u "$user" -- env WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/"$uid" QT_QPA_PLATFORM=wayland kscreen-doctor "$@" >/dev/null 2>&1; }
state() { echo "$(cat "$conn/status")/$(cat "$conn/enabled")"; }

# Follow DP-2 for $1 seconds; print every change with its offset in ms.
follow() {
  local end=$(( $(date +%s%N) + $1 * 1000000000 )) last="" now t0=$(date +%s%N)
  while [ "$(date +%s%N)" -lt "$end" ]; do
    now=$(state)
    if [ "$now" != "$last" ]; then echo "    +$(( ($(date +%s%N) - t0) / 1000000 ))ms $now"; last=$now; fi
    sleep 0.05
  done
}

wake_modeset() { kdoctor --dpms on; }
# Record exactly which system calls ddcutil makes, so a working wake can be reproduced byte for byte.
wake_ddcutil() {
  if command -v strace >/dev/null 2>&1; then
    strace -f -tt -e trace=openat,ioctl,read,write,pread64,pwrite64 -o "/home/$user/wake-lab-ddcutil.$(date +%H%M%S).strace" \
      ddcutil --disable-flock --bus "$bus" getvcp D6 >/dev/null 2>&1
  else
    ddcutil --disable-flock --bus "$bus" getvcp D6 >/dev/null 2>&1
  fi
}
wake_aux_read() { dd if="$aux" bs=1 count=1 status=none >/dev/null 2>&1; }
wake_aux_power() { printf "\x01" | dd of="$aux" bs=1 seek=1536 conv=notrunc status=none 2>/dev/null; }
wake_edid_read() { dd if="$conn/edid" bs=1 count=1 status=none >/dev/null 2>&1; i2ctransfer -y "$bus" w1@0x50 0x00 r1 >/dev/null 2>&1; }

run() {
  local name=$1 fn=$2
  kdoctor --dpms off
  sleep $(( asleep_minutes * 60 ))
  local since; since=$(date "+%F %T")
  {
    echo "== $name  $(date +%T)  before=$(state)  (asleep ${asleep_minutes} min)"
    "$fn"; echo "    sent, exit=$?"
    if [ "$fn" != wake_modeset ]; then
      follow 8
      echo "    after 8 s: $(state); now kscreen-doctor --dpms on"
      kdoctor --dpms on
    fi
    follow 12
    echo "    final=$(state)  link errors=$(journalctl -k --since "$since" --no-pager | grep -c dpcd_set_link_settings)  hotplugs=$(journalctl -b --since "$since" --no-pager | grep -c "prop_hotplug: *1")"
  } >>"$log" 2>&1
}

echo "wake-lab started $(date)  conn=$conn aux=$aux bus=$bus kernel=$(uname -r)" >>"$log"
for round in 1 2; do
  run "A modeset only (baseline)" wake_modeset
  run "B ddcutil getvcp D6" wake_ddcutil
  run "C one AUX read of DPCD 0x000" wake_aux_read
  run "D AUX write DPCD 0x600 = D0 (SET_POWER)" wake_aux_power
  run "E EDID read" wake_edid_read
done
kdoctor --dpms on
echo "wake-lab finished $(date)" >>"$log"
