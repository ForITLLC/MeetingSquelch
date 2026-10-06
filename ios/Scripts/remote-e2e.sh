#!/bin/bash
# remote-e2e.sh: build ios/Scripts/remote-e2e.swift with the phone's SquelchRemote and the Mac's real RemoteServer
# into one binary and run it on port 47298, with its own log file, so a running Squelch is never touched.
# SQUELCH_SKIP_BONJOUR=1 skips the Bonjour check (a runner without multicast).
set -euo pipefail
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"
cp ios/Scripts/remote-e2e.swift "$TMP/src/main.swift"
# One module here, so the kit's "import SquelchProtocol" lines go.
for f in ios/SquelchKit/Sources/SquelchProtocol/*.swift ios/SquelchKit/Sources/SquelchRemote/*.swift; do
  grep -v 'import SquelchProtocol' "$f" > "$TMP/src/$(basename "$f")"
done
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" \
  "$TMP"/src/*.swift Sources/RemoteServer.swift Sources/Log.swift -o "$TMP/remote-e2e"
status=0
SQUELCH_LOG="$TMP/Squelch.log" "$TMP/remote-e2e" || status=$?
echo "--- server log"
cat "$TMP/Squelch.log" 2>/dev/null || true
exit $status
