#!/bin/bash
# remote-harness.sh: build tests/remote-harness.swift against the real RemoteServer and run it on port 47299,
# with its own log file, so the running Squelch and its log are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
mkdir -p "$TMP/src"
cp tests/remote-harness.swift "$TMP/src/main.swift"
swiftc -swift-version 5 -target arm64-apple-macos14.2 \
  "$TMP/src/main.swift" Sources/RemoteServer.swift Sources/Log.swift \
  ios/SquelchKit/Sources/SquelchProtocol/*.swift -o "$TMP/remote-harness"
status=0
SQUELCH_LOG="$TMP/Squelch.log" "$TMP/remote-harness" || status=$?
echo "--- server log"
cat "$TMP/Squelch.log"
rm -rf "$TMP"
exit $status
