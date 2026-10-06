# Contributing to Squelch

Thanks for helping. Bug reports, call-app fixes (a call app renamed its mute button again) and pull requests
are all welcome.

## Sign off your commits (DCO)

Squelch uses the [Developer Certificate of Origin](https://developercertificate.org/) (DCO), not a contributor
license agreement. By adding a `Signed-off-by` line to a commit you state that you wrote the change, or
otherwise have the right to submit it under this project's license. Your contribution is licensed under
GPL-3.0-only, like the rest of Squelch.

Sign off with `git commit -s`, which adds a line with your name and email:

```
Signed-off-by: Your Name <you@example.com>
```

Use your real name. Pull requests with unsigned commits cannot be merged.

## Before you open a pull request

- The Mac app builds: `./build.sh` (see README.md for the extension key).
- If you touched the iPhone remote or its protocol: `cd ios/SquelchKit && swift test`, and keep
  `docs/remote-protocol.md` in step with `RemoteProtocol.swift`.
- If you touched `extension/` or `Sources/WebBridge.swift`: run `tests/extension-harness.js` against your
  build with no call up (README.md, Tests).
- Say which call apps, versions and browsers you checked by hand. Squelch presses buttons inside other apps,
  and those apps change their labels without notice, so a short note of what you saw helps.

## Style

- Keep the code close to what is there: small files, plain Swift, a comment at the top of each file saying what
  it does.
- In anything a user reads, spell the shortcut out: Control + Option + Shift + Command + M.
- Never commit keys, certificates or provisioning profiles. `.gitignore` covers the usual ones.

Security problems go through SECURITY.md, not issues or pull requests.
