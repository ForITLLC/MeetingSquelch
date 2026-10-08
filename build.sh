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
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" build/obj build/intents
# App Intents (Sources/Intents.swift): the compiler writes the intents' compile-time values for the protocols Xcode
# lists, and Xcode's appintentsmetadataprocessor turns them into Contents/Resources/Metadata.appintents, which is
# how Shortcuts finds them. Both need full Xcode, not just the Command Line Tools. Paths are absolute because the
# processor matches each value's source file against the list.
PROCESSOR=$(xcrun --find appintentsmetadataprocessor 2>/dev/null) || { echo "no appintentsmetadataprocessor: install Xcode" >&2; exit 1; }
SOURCES=("$PWD"/Sources/*.swift "$PWD"/ios/SquelchKit/Sources/SquelchProtocol/*.swift)
printf '%s\n' "${SOURCES[@]}" > build/intents/sources.txt
echo '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider",
"AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider",
"_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]' > build/intents/protocols.json
for arch in $ARCHS; do
  swiftc -O -wmo -swift-version 5 -module-name Squelch -target "$arch-apple-macos14.2" \
    -framework AppKit -framework Carbon -framework CoreAudio -framework ApplicationServices \
    -framework Network -framework SystemConfiguration -framework CoreImage -framework ServiceManagement \
    -emit-const-values-path "$PWD/build/intents/Squelch-$arch.swiftconstvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$PWD/build/intents/protocols.json" \
    "${SOURCES[@]}" -o "build/obj/Squelch-$arch"
done
FIRST=${ARCHS%% *}
echo "$PWD/build/intents/Squelch-$FIRST.swiftconstvalues" > build/intents/consts.txt
"$PROCESSOR" --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" --module-name Squelch \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family macOS --deployment-target 14.2 --target-triple "$FIRST-apple-macos14.2" \
  --bundle-identifier io.forit.squelch --output "$OUT/Contents/Resources" --binary-file "build/obj/Squelch-$FIRST" \
  --source-file-list build/intents/sources.txt --swift-const-vals-list build/intents/consts.txt \
  --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization 2>&1 | { grep -v '^\s*$' || true; } | tail -3
[[ -f $OUT/Contents/Resources/Metadata.appintents/extract.actionsdata ]] || { echo "App Intents metadata missing" >&2; exit 1; }
if [[ $(wc -w <<< "$ARCHS") -gt 1 ]]; then
  lipo -create build/obj/Squelch-* -output "$OUT/Contents/MacOS/Squelch"
else
  mv build/obj/Squelch-* "$OUT/Contents/MacOS/Squelch"
fi
rm -rf build/obj build/intents
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
