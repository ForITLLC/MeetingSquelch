#!/bin/bash
# sim-smoke.sh: the built app in a throwaway iPhone simulator, paired with a stand-in Mac (fake-mac.swift, the
# Mac's real RemoteServer). Passes when the app pairs from the link, the server logs "iPhone connected", and the
# keychain group works (the app reads its pairing back after a relaunch and connects again). Leaves a screenshot
# of the connected remote in $OUT. Never touches a running Squelch or another job's simulator.
#
#   ios/Scripts/sim-smoke.sh <path to Squelch.app built for the simulator, ad-hoc signed> [out dir]
#
# The app has to be a Debug build (it reads SQUELCH_PAIR_URL at launch only in Debug) and signed with "-", not
# CODE_SIGNING_ALLOWED=NO, so its keychain-access-groups entitlement applies.
set -euo pipefail
APP=${1:?usage: sim-smoke.sh <Squelch.app> [out dir]}
OUT=${2:-/tmp/squelch-sim-smoke}
cd "$(dirname "$0")/../.."
mkdir -p "$OUT"
TMP=$(mktemp -d)
UDID=""
SERVER=""
cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  if [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl delete "$UDID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/src"
cp ios/Scripts/fake-mac.swift "$TMP/src/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" "$TMP/src/main.swift" \
  Sources/RemoteServer.swift Sources/Log.swift ios/SquelchKit/Sources/SquelchProtocol/*.swift -o "$TMP/fake-mac"
SQUELCH_LOG="$OUT/fake-mac.log" "$TMP/fake-mac" "$TMP/pair.url" 300 > "$OUT/fake-mac.out" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do [ -s "$TMP/pair.url" ] && break; sleep 0.25; done
test -s "$TMP/pair.url" || { echo "FAIL the stand-in Mac never opened pairing"; cat "$OUT/fake-mac.out"; exit 1; }

# A simulator of its own, the same model and runtime as the newest iPhone this Mac has, deleted on exit.
BASE=$(python3 ios/Scripts/ci_simulator.py iphone)
read -r DEVTYPE RUNTIME < <(xcrun simctl list -j devices | python3 -c '
import json, sys
for rt, ds in json.load(sys.stdin)["devices"].items():
    for d in ds:
        if d["udid"] == sys.argv[1]: print(d["deviceTypeIdentifier"], rt)
' "$BASE")
UDID=$(xcrun simctl create "squelch-smoke-$$" "$DEVTYPE" "$RUNTIME")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl install "$UDID" "$APP"

connected() { grep -cE "remote: .+ connected$" "$OUT/fake-mac.log" 2>/dev/null || true; }
wait_connected() {  # $1 = how many connections the log should show
  for _ in $(seq 1 60); do [ "$(connected)" -ge "$1" ] && return 0; sleep 0.5; done
  return 1
}

fail=0
SIMCTL_CHILD_SQUELCH_PAIR_URL="$(cat "$TMP/pair.url")" xcrun simctl launch "$UDID" io.forit.squelch > /dev/null
if wait_connected 1; then echo "PASS pairs from the link and connects"; else echo "FAIL no connection after pairing"; fail=1; fi
grep -q "paired a new phone" "$OUT/fake-mac.log" && echo "PASS the Mac lists the phone" || { echo "FAIL the Mac never paired"; fail=1; }
sleep 2
xcrun simctl io "$UDID" screenshot "$OUT/remote.png" > /dev/null 2>&1 || true

# Relaunch without the link: the pairing has to come back out of the keychain group.
xcrun simctl terminate "$UDID" io.forit.squelch
xcrun simctl launch "$UDID" io.forit.squelch > /dev/null
if wait_connected 2; then echo "PASS reconnects from the stored pairing"; else echo "FAIL no reconnect from the keychain"; fail=1; fi

echo "--- stand-in Mac log"
cat "$OUT/fake-mac.log"
exit $fail
