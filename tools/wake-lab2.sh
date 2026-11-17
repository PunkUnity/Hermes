#!/usr/bin/env bash
# Unattended check of the exact wake Hermes will use: as the desktop user, one
# EDID read on the DisplayPort AUX I2C adapter of DP-2, then only watch.
# Run as root (systemd-run). Results: /home/kyprian/wake-lab2.log
user=kyprian
uid=$(id -u "$user")
conn=$(ls -d /sys/class/drm/card*-DP-2 | head -n 1)
log=/home/$user/wake-lab2.log
asleep_minutes=${ASLEEP_MINUTES:-16}
auxi2c=$(basename "$(ls -d "$conn"/i2c-* 2>/dev/null | head -n 1)")
ddc=$(basename "$(readlink "$conn/ddc" 2>/dev/null)")

kdoctor() { runuser -u "$user" -- env WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/"$uid" QT_QPA_PLATFORM=wayland kscreen-doctor "$@" >/dev/null 2>&1; }
state() { echo "$(cat "$conn/status")/$(cat "$conn/enabled")"; }
follow() {
  local end=$(( $(date +%s%N) + $1 * 1000000000 )) last="" now t0=$(date +%s%N)
  while [ "$(date +%s%N)" -lt "$end" ]; do
    now=$(state)
    if [ "$now" != "$last" ]; then echo "    +$(( ($(date +%s%N) - t0) / 1000000 ))ms $now"; last=$now; fi
    sleep 0.05
  done
}
# The same system calls Hermes makes: open, ioctl(I2C_SLAVE, 0x50), write 1 byte, read 1 byte.
edid_read() {
  runuser -u "$user" -- python3 -c "
import os, fcntl, sys
try:
    fd = os.open('/dev/$auxi2c', os.O_RDWR)
except OSError as e:
    print('    open failed:', e); sys.exit(2)
try:
    fcntl.ioctl(fd, 0x0703, 0x50)
    os.write(fd, bytes([0])); os.read(fd, 1)
    print('    monitor answered'); sys.exit(0)
except OSError as e:
    print('    no answer:', e); sys.exit(1)
"
}

{
  echo "wake-lab2 started $(date)  conn=$conn  aux i2c adapter=$auxi2c ($(cat "$conn/$auxi2c/name" 2>/dev/null))  ddc symlink=$ddc  kernel=$(uname -r)"
  ls -l "/dev/$auxi2c"
} >>"$log" 2>&1
[ -n "$auxi2c" ] || { echo "no AUX I2C adapter under $conn; stopping" >>"$log"; exit 1; }

echo "== awake check $(date +%T) (monitor on): expect answered" >>"$log"
kdoctor --dpms on; sleep 10; edid_read >>"$log" 2>&1

for round in 1 2; do
  kdoctor --dpms off
  sleep $(( asleep_minutes * 60 ))
  since=$(date "+%F %T")
  {
    echo "== F EDID read on $auxi2c as $user  $(date +%T)  before=$(state)  (asleep ${asleep_minutes} min)"
    edid_read; echo "    exit=$?"
    follow 10
    echo "    after 10 s: $(state); now kscreen-doctor --dpms on"
    kdoctor --dpms on
    follow 8
    echo "    final=$(state)  link errors=$(journalctl -k --since "$since" --no-pager | grep -c dpcd_set_link_settings)"
  } >>"$log" 2>&1
done
echo "wake-lab2 finished $(date)" >>"$log"
