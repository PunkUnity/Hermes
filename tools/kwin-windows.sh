#!/usr/bin/env bash
# List every window KWin manages, bottom to top (the last line is on top):
# stacking position, class, PID, type (normal/dialog/utility/…), output,
# geometry, fullscreen / minimized / keep-above, which one has focus (ACTIVE),
# and the title. Desktop and panel windows are left out.
# Usage: bash kwin-windows.sh   (run as the desktop user; works over SSH)
set -u
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
tag="hermes-windows-$$"
js="$(mktemp --suffix=.js)"
cat > "$js" <<JS
const list = workspace.stackingOrder ? workspace.stackingOrder : workspace.windowList();
for (const w of list) {
  if (w.desktopWindow || w.dock) continue;
  const type = w.normalWindow ? "normal" : w.dialog ? "dialog" : w.utility ? "utility" :
               w.popupMenu || w.dropdownMenu ? "menu" : w.notification || w.criticalNotification ? "notification" :
               w.splash ? "splash" : w.tooltip ? "tooltip" : "other";
  const g = w.frameGeometry;
  print("$tag " + w.stackingOrder + " | " + w.resourceClass + " | pid " + w.pid + " | " + type + " | " +
        (w.output ? w.output.name : "?") + " | " + Math.round(g.x) + "," + Math.round(g.y) + " " +
        Math.round(g.width) + "x" + Math.round(g.height) +
        (w.fullScreen ? " | fullscreen" : "") + (w.minimized ? " | minimized" : "") +
        (w.keepAbove ? " | above" : "") + (w === workspace.activeWindow ? " | ACTIVE" : "") + " | " + w.caption);
}
JS
since="$(date '+%Y-%m-%d %H:%M:%S')"
id="$(busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss "$js" "$tag" | awk '{print $2}')"
busctl --user call org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script run >/dev/null
sleep 1
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s "$tag" >/dev/null
journalctl --user --since "$since" --no-pager -o cat | grep -F "$tag" | sed "s/.*$tag //"
rm -f "$js"
