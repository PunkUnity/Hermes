#!/usr/bin/env bash
# List every normal window KWin manages: window class, PID, output, fullscreen, title.
# Usage: bash kwin-windows.sh   (run as the desktop user; works over SSH)
set -u
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
tag="hermes-windows-$$"
js="$(mktemp --suffix=.js)"
cat > "$js" <<JS
for (const w of workspace.windowList()) {
  if (!w.normalWindow) continue;
  print("$tag " + w.resourceClass + " | pid " + w.pid + " | " + (w.output ? w.output.name : "?") +
        (w.fullScreen ? " | fullscreen" : "") + " | " + w.caption);
}
JS
since="$(date '+%Y-%m-%d %H:%M:%S')"
id="$(busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss "$js" "$tag" | awk '{print $2}')"
busctl --user call org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script run >/dev/null
sleep 1
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s "$tag" >/dev/null
journalctl --user --since "$since" --no-pager -o cat | grep -F "$tag" | sed "s/.*$tag //"
rm -f "$js"
