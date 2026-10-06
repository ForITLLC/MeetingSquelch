# ForIT Squelch

Squelch is a universal call mute for the Mac. One shortcut, **Control + Option + Shift + Command + M**, mutes you
inside whatever call app is up, so the other people on the call see that you are muted. With no call up it
flips the microphone's own mute switch instead.

- **Desktop apps:** Zoom, Microsoft Teams, Webex, Slack huddles, Discord and FaceTime (microphone only). Squelch
  presses the app's own mute control through the macOS Accessibility API.
- **Browser calls:** Google Meet, Microsoft Teams, Zoom and Webex in Chrome or Edge tabs, through the Squelch
  browser extension in `extension/`. It talks to the app over a WebSocket on 127.0.0.1 only.
- **Menu bar strip:** microphone, camera and leave controls for the current call.
- **iPhone remote** (`ios/`): mute and camera buttons for the phone, Control Center, the Lock Screen and the
  Action button. It pairs with the Mac by QR code over the local network (`docs/remote-protocol.md`).

Signed, notarized builds with updates are available from ForIT. This repository is the source for those builds.

## Building the Mac app from source

You need a Mac on macOS 14.2 or later with the Xcode Command Line Tools (Swift 5.9 or later), which bring
Python 3. `openssl` comes with macOS.

Clone this repository (https://github.com/ForITLLC/MeetingSquelch) and, in its folder:

1. Make a key for signing the browser extension. Keep it out of git; it decides your extension's ID.

   ```sh
   mkdir -p ~/.config/squelch
   openssl genrsa -out ~/.config/squelch/extension-signing-key.pem 2048
   ```

2. Build and install. `build.sh` reads the key from `SQUELCH_EXTENSION_KEY` (its default is the path above),
   builds `build/Squelch.app` for Apple silicon (ad-hoc signed), and with `--install` copies it to
   `/Applications` and loads the LaunchAgent `io.forit.squelch` so it starts at login.

   ```sh
   SQUELCH_EXTENSION_KEY=~/.config/squelch/extension-signing-key.pem ./build.sh --install
   ```

   It prints `packed extension <id> <version>`: that ID belongs to the extension packed with your key.
   `SQUELCH_ARCHS="arm64 x86_64"` builds one binary for Apple silicon and Intel.

3. Allow Squelch under System Settings > Privacy & Security > Accessibility. Without that it cannot press
   mute inside the call apps.

### The browser extension

Out of the box the app only talks to ForIT's extension, the one signed with ForIT's key. To use your own:

1. Load it: open `chrome://extensions` (or `edge://extensions`), turn on Developer mode, choose **Load
   unpacked** and pick the `extension/` folder. The page shows the extension's ID. (Chrome and Edge install a
   packed `.crx` from outside their stores only through enterprise policy, `ExtensionInstallForcelist` pointed
   at `file:///Applications/Squelch.app/Contents/Resources/squelch-extension.xml`; that one has the ID
   `build.sh` printed.)
2. Tell the app to accept that ID, then restart it:

   ```sh
   defaults write io.forit.squelch extensionIDs -array <your extension id>
   launchctl kickstart -k gui/$(id -u)/io.forit.squelch
   ```

   The list replaces ForIT's ID; name several IDs to allow several. An empty array
   (`defaults write io.forit.squelch extensionIDs -array`) lets any browser extension connect, which is for
   development only. `defaults delete io.forit.squelch extensionIDs` goes back to ForIT's.

### Tests

- `tests/extension-harness.js` runs the extension's real scripts in Node 22 or later against the running app,
  with fake Meet, Teams and Zoom pages. It connects as ForIT's extension ID unless you give it yours:

  ```sh
  SQUELCH_EXTENSION_ID=<your extension id> node tests/extension-harness.js extension
  ```

  It presses mute, camera, share and leave through `squelch://` URLs, so run it with no call up. It refuses to
  start while a call or a recording is live.
- `tests/remote-harness.sh` builds the app's remote server with a test client and checks the iPhone remote
  protocol on port 47299 (Apple silicon). It leaves the running app alone.
- `cd ios/SquelchKit && swift test` runs the iPhone remote's tests on the Mac, with no signing.

### Your build and ForIT's

A build from this source keeps the bundle ID `io.forit.squelch`, so it shares its settings, its Accessibility
entry and the `squelch://` URL scheme with an installed ForIT build. Run one or the other, not both.

## Building the iPhone remote

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The project is signed for
ForIT's Apple team, so before building:

- In `ios/project.yml`, set `DEVELOPMENT_TEAM` to your own team ID for both targets, change the bundle IDs
  (`io.forit.squelch` and `io.forit.squelch.controls`) to your own, and use your own signing (for example
  `CODE_SIGN_STYLE: Automatic` without the `CODE_SIGN_IDENTITY` and `PROVISIONING_PROFILE_SPECIFIER` lines).
- In `ios/SquelchKit/Sources/SquelchRemote/PairingStore.swift`, set `accessGroup` to
  `<your team ID>.<your app's bundle ID>`, and use the same bundle ID in the `keychain-access-groups` entries of
  `ios/App/Squelch.entitlements` and `ios/Controls/SquelchControls.entitlements`. The app and its Controls
  extension share the pairing through that keychain group.

Then `cd ios && xcodegen` and open `Squelch.xcodeproj`.

## Trademarks

The GPL covers the code, not the names. "ForIT", "Squelch" and the Squelch icon identify ForIT LLC's builds.
If you ship builds of a fork, give it its own name, icon and bundle IDs.

## License

Copyright © 2026 ForIT LLC.

Squelch is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
License, version 3 only (GPL-3.0-only), as published by the Free Software Foundation. It is distributed in the
hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

Security issues: see [SECURITY.md](SECURITY.md). Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
