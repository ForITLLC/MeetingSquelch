#!/bin/bash
# mic-harness.sh: build tests/mic-harness.swift against the real MicPick, MicWatcher and SystemMic and run it,
# with its own log file. It only reads Core Audio: no mute, no press, no device change, so it is safe during a call.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
mkdir -p "$TMP/src"
cp tests/mic-harness.swift "$TMP/src/main.swift"
swiftc -swift-version 5 -target arm64-apple-macos14.2 -framework AppKit -framework CoreAudio \
  "$TMP/src/main.swift" Sources/MicPick.swift Sources/MicWatcher.swift Sources/SystemMic.swift Sources/Log.swift \
  -o "$TMP/mic-harness"
status=0
SQUELCH_LOG="$TMP/Squelch.log" "$TMP/mic-harness" || status=$?
rm -rf "$TMP"
exit $status
