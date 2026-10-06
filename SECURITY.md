# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub: open this repository's **Security** tab and choose
**Report a vulnerability**. Do not open a public issue, pull request or discussion for a security problem.

Include what you found, the steps to reproduce it, the Squelch version
(`defaults read /Applications/Squelch.app/Contents/Info.plist CFBundleShortVersionString`) and the macOS or iOS
version.

ForIT replies in the private report and works on a fix there before anything is made public.

## Supported versions

Fixes go into the latest release only. Please check that a problem still happens on the current source before
reporting it.

## What is in scope

- The browser bridge: the WebSocket on 127.0.0.1 port 47213 and its checks on the Origin and the extension ID
  (`Sources/WebBridge.swift`), and the extension in `extension/`.
- The iPhone remote: the server on port 47214, pairing and the sealed frames (`Sources/RemoteServer.swift`,
  `ios/SquelchKit`, `docs/remote-protocol.md`).
- The `squelch://` URL scheme and anything that lets another app or web page press mute, camera, share or leave.
- Build and install scripts (`build.sh`, `tools/`).

Problems in the call apps themselves (Zoom, Teams, Meet and the rest) belong with their vendors.
