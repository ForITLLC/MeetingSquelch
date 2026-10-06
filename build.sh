#!/bin/bash
# build.sh: build Squelch.app. --install also puts it in /Applications and (re)loads LaunchAgent io.forit.squelch
# (tools/install.sh). The default is a local build: Apple silicon only, ad-hoc signed with a designated
# requirement of the bundle ID only, so the Accessibility grant survives rebuilds (TCC matches the requirement,
# not the hash). A release build (the signed download) sets:
#   SQUELCH_ARCHS="arm64 x86_64"   one binary for Apple silicon and Intel
#   SQUELCH_SIGN=<identity>        sign with that certificate, hardened runtime and a secure timestamp
#   SQUELCH_KEYCHAIN=<path>        the keychain holding that identity, when it is not on the search list
#   SQUELCH_BUILD_NUMBER=<n>       CFBundleVersion
# The iPhone remote's wire protocol (ios/SquelchKit/Sources/SquelchProtocol) is compiled in from the iOS kit.
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/Squelch.app
ARCHS=${SQUELCH_ARCHS:-arm64}
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" build/obj
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.2" \
    -framework AppKit -framework Carbon -framework CoreAudio -framework ApplicationServices \
    -framework Network -framework SystemConfiguration -framework CoreImage -framework ServiceManagement \
    Sources/*.swift ios/SquelchKit/Sources/SquelchProtocol/*.swift -o "build/obj/Squelch-$arch"
done
if [[ $(wc -w <<< "$ARCHS") -gt 1 ]]; then
  lipo -create build/obj/Squelch-* -output "$OUT/Contents/MacOS/Squelch"
else
  mv build/obj/Squelch-* "$OUT/Contents/MacOS/Squelch"
fi
rm -rf build/obj
cp Info.plist "$OUT/Contents/Info.plist"
[[ -n ${SQUELCH_BUILD_NUMBER:-} ]] && plutil -replace CFBundleVersion -string "$SQUELCH_BUILD_NUMBER" "$OUT/Contents/Info.plist"
cp assets/icon/Squelch.icns "$OUT/Contents/Resources/Squelch.icns"
# The browser extension ships inside the app, signed with the key in SQUELCH_EXTENSION_KEY (never in git):
# a browser policy (ExtensionInstallForcelist) can install it from file:///Applications/Squelch.app/Contents/Resources/squelch-extension.xml.
KEY=${SQUELCH_EXTENSION_KEY:-"$HOME/.config/squelch/extension-signing-key.pem"}
[[ -f $KEY ]] || { echo "no extension signing key at $KEY (set SQUELCH_EXTENSION_KEY)" >&2; exit 1; }
python3 tools/pack-crx.py extension "$KEY" "$OUT/Contents/Resources" file:///Applications/Squelch.app/Contents/Resources
if [[ -n ${SQUELCH_SIGN:-} ]]; then
  codesign --force --options runtime --timestamp --sign "$SQUELCH_SIGN" \
    ${SQUELCH_KEYCHAIN:+--keychain "$SQUELCH_KEYCHAIN"} "$OUT"
else
  codesign --force --sign - --identifier io.forit.squelch \
    --requirements '=designated => identifier "io.forit.squelch"' "$OUT"
fi
echo "built $OUT ($(lipo -archs "$OUT/Contents/MacOS/Squelch"))"

[[ "${1:-}" == --install ]] || exit 0
tools/install.sh "$OUT"
