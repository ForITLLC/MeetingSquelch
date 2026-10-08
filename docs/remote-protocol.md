# The iPhone remote protocol (forit.squelch.remote v1)

How the iPhone app (`ios/`) talks to Squelch on the Mac. The code is
`ios/SquelchKit/Sources/SquelchProtocol/RemoteProtocol.swift`; both sides compile that one file, so this page and
that file must agree. Tests: `cd ios/SquelchKit && swift test` (on a Mac).

## Finding the Mac

- The remote is off until the user turns it on: **Pair iPhone…** in the menu turns it on and **Turn Off iPhone
  Remote** turns it off (defaults key `remote`). A Mac that paired a phone before the remote was opt-in stays on.
- While it is on, Squelch listens on TCP port **47214** (defaults key `remotePort`) on every interface. That is a
  WebSocket server, and the browser extension's port 47213 stays loopback only.
- It advertises Bonjour **`_squelch._tcp`** under the Mac's computer name. TXT record: `v=1`, `id=<mac id>`.
- The mac id is a random UUID made once and kept in `~/Library/Application Support/Squelch/remote.json`.
- The phone looks for the paired Mac's `id` with NWBrowser. If Bonjour finds nothing within 2 s, it tries the
  `host` and `port` from the pairing code, and then the last address that worked.

## Pairing: a QR code on the Mac's screen

1. You pick **Pair iPhone…** in the Squelch menu. The Mac makes a fresh 32-byte key and shows it as a QR code
   in a window for five minutes, for one phone:
   `squelch-pair://v1?m=<mac id>&n=<mac name>&k=<key, base64url>&p=47214&h=<host>.local`
2. The phone reads it with the iPhone Camera app (the app registers the `squelch-pair` URL scheme) or with the
   scanner in the app. It picks a device id (a UUID) for this Mac and stores the key, mac id, name, host and
   port in its Keychain.
3. The phone connects with `pair: true` in its hello. The Mac uses the pending pairing key for it. The first
   sealed frame that opens proves the phone holds the key. The Mac then saves the device id, name and key to
   `remote.json` (mode 0600), closes the window and logs `remote: paired <name>`.

Nothing else gets a key. A 256-bit key read off the screen needs no password exchange. Anyone who can see the
screen while the window is open could pair. You see each paired phone under **Paired iPhones** and can remove it.

## A connection

WebSocket text frames first, then binary frames only:

```
phone -> Mac  {"t":"hello","proto":"forit.squelch.remote","v":1,"device":"<id>","nonce":"<b64 16 bytes>","pair":true?}
Mac -> phone  {"t":"challenge","mac":"<mac id>","nonce":"<b64 16 bytes>"}
              or {"t":"error","why":"not paired" | "bad hello" | "pairing closed"}, then close
```

Both sides then derive keys with HKDF-SHA256. The input is the 32-byte key. The salt is the phone nonce
followed by the Mac nonce. The info string is `forit.squelch.remote v1|<device>|<mac>`. The output is 64 bytes:
the first 32 are phone→Mac, the last 32 are Mac→phone. Every later frame is a binary ChaCha20-Poly1305 sealed box in combined form:

- The nonce is 4 zero bytes plus an 8-byte big-endian counter. The counter starts at 1 and goes up by one per
  frame in each direction.
- The receiver drops the connection on any frame that fails to open, or whose counter is not above the last.
- The Mac counts a connection as authenticated only after its first frame opens. Until then it carries out no
  press. It sends its own sealed frames only after the challenge.

## Messages (sealed JSON; unused fields are left out)

| From | Message | Meaning |
|---|---|---|
| phone | `{"t":"hi","name":"My iPhone"}` | first frame; the name shows in **Paired iPhones** |
| phone | `{"t":"do","id":7,"what":"mic"}` | a press. `what`: `mic` `camera` `share` `leave` `front`. Same routes as the shortcut and the menu bar |
| phone | `{"t":"ping"}` | keepalive every 20 s; the Mac answers `pong` |
| Mac | `{"t":"state","app":"Zoom","muted":true,"camera":false,"share":false}` | after `hi`, and on every change |
| Mac | `{"t":"state","muted":false,"mic":"RØDE Wireless MICRO"}` | no call: `muted` is the Mac's mic, nil if it has no mute switch |
| Mac | `{"t":"done","id":7,"what":"mic","ok":true,"muted":true}` | the result of press 7, once it has been read back |
| Mac | `{"t":"bye","why":"unpaired"}` | You removed this phone; it forgets the Mac |

A `do` from the phone is a real press in a live call, exactly like the shortcut. The phone shows the state it
was sent, never a guess.

## Limits

- The phone works only on the same network as the Mac. A relay would be needed beyond that; none exists yet.
- iOS asks for Local Network access the first time. The app's Info.plist declares `NSBonjourServices`
  `_squelch._tcp` and `NSLocalNetworkUsageDescription`.
