#!/bin/bash
# tools/install.sh <Squelch.app>: put a built Squelch.app in /Applications on this Mac and (re)load LaunchAgent
# io.forit.squelch, so it runs at login and restarts after a crash. Takes a local build (build.sh --install
# calls it with build/Squelch.app) or a release copied out of the DMG.
set -euo pipefail
SRC=${1:?usage: tools/install.sh <path to Squelch.app>}
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
cd "$(dirname "$0")/.."
[[ -x $SRC/Contents/MacOS/Squelch ]] || { echo "not a Squelch.app: $SRC" >&2; exit 1; }
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
AGENT=~/Library/LaunchAgents/io.forit.squelch.plist
# Squelch was CallMute until 2026-10-06. Both want the same shortcut and port, so the old copy stops first
# and is deleted only once Squelch is running; if Squelch does not come up, CallMute is brought back.
OLD_AGENT=~/Library/LaunchAgents/io.forit.callmute.plist
launchctl bootout "gui/$(id -u)/io.forit.squelch" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/io.forit.callmute" 2>/dev/null || true
pkill -x Squelch 2>/dev/null || true
pkill -x CallMute 2>/dev/null || true
sleep 0.5
# A fresh copy, never an in-place overwrite: macOS kills a signed binary rewritten in place.
rm -rf /Applications/Squelch.app.new
ditto "$SRC" /Applications/Squelch.app.new
rm -rf /Applications/Squelch.app
mv /Applications/Squelch.app.new /Applications/Squelch.app
"$LSREG" -f /Applications/Squelch.app
# macOS registers the source copy too; unregister it so squelch:// can never start a second copy from there.
[[ $SRC == /Applications/Squelch.app ]] || "$LSREG" -u "$SRC" 2>/dev/null || true
cp io.forit.squelch.plist "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
for _ in $(seq 20); do pgrep -x Squelch >/dev/null && break; sleep 0.5; done
if ! pgrep -x Squelch >/dev/null; then
  echo "Squelch did not start" >&2
  [[ -f $OLD_AGENT ]] && launchctl bootstrap "gui/$(id -u)" "$OLD_AGENT" && echo "CallMute brought back" >&2
  exit 1
fi
if [[ -e $OLD_AGENT || -e /Applications/CallMute.app ]]; then
  rm -f "$OLD_AGENT"
  [[ -e /Applications/CallMute.app ]] && "$LSREG" -u /Applications/CallMute.app
  rm -rf /Applications/CallMute.app
  echo "removed CallMute.app and LaunchAgent io.forit.callmute"
fi
echo "installed /Applications/Squelch.app $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  /Applications/Squelch.app/Contents/Info.plist) and loaded io.forit.squelch (pid $(pgrep -x Squelch))"
