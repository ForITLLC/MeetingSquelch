// Squelch: native universal mute for the Mac.
// One shortcut (Control + Option + Shift + Command + M) mutes you inside the call app, so the
// others see it; with no call it flips the mic's own mute switch, the one SoundSource shows.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
