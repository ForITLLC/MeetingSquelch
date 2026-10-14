// CallBar.swift: the menu bar item. With no call it is the mic icon and a click opens the menu.
// The mic icon: hollow = nothing is using the mic, solid = an app is listening, red slash = muted.
// In a call it becomes a strip: the app name (opens the menu), the mic (red when muted), the camera,
// and leave. Leave needs a second click within 3 s, so a stray click never drops the call. The mic's
// name stays out of the strip (2026-10-12: "Jabra Speak 710" in the menu bar was too wide): the
// tooltip, the menu and VoiceOver name the mic the call records from (the Jabra, not the Mac's default).
// With no call the shortcut acts on the default input: the tooltip and menu name it.
// The strip is one image, drawn only when something changes, so the item has no subviews: with
// subviews AppKit kept re-copying the item to every display's menu bar (NSStatusItem
// _updateReplicants) at about 35% CPU. Copying flips the button's appearance once per display, so
// nothing here may redraw on an appearance change either (that looped at 100%): the image works its
// colors out each time it is drawn. The click's x position in that image picks the part.
// A right click, or a press with no mouse (VoiceOver, scripts), opens the menu, which has every action.
import AppKit

struct BarState: Equatable {
    var app: String?            // nil = no call
    var muted: Bool?
    var camera: Bool??          // nil = no camera control; .some(nil) = a camera toggle of unknown state
    var leave = false
    var listening = false       // no call: some app is using the mic
    var mic: String?            // the mic named: in a call the one it records from, else the default input
}

final class CallBar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu: NSMenu
    var onMic: () -> Void = {}
    var onCamera: () -> Void = {}
    var onLeave: () -> Void = {}
    private var armTimer: Timer?
    private var state = BarState()
    private var drawn: (BarState, Bool)?
    private var spans: [(name: String, x: ClosedRange<CGFloat>)] = [] // each part's place in the strip image

    private enum Glyph {
        case text(String, NSColor?)     // nil color = the menu bar's own text color
        case symbol(String, NSColor?)
    }

    var inCall: Bool { state.app != nil }

    // What is visible, for status.json: e.g. "Teams | mic muted | camera on | leave". The mic's name is
    // status.json's callMic and mic.
    var summary: String {
        guard let app = state.app else {
            if state.muted == true { return "mic muted" }
            return "mic \(state.listening ? "in use" : "not in use")" + (state.muted == nil ? ", no mute switch" : "")
        }
        var parts = [app, "mic \(word(state.muted))"]
        if let cam = state.camera { parts.append("camera \(cam.map { $0 ? "on" : "off" } ?? "toggle")") }
        if state.leave { parts.append(armTimer != nil ? "leave (armed)" : "leave") }
        return parts.joined(separator: " | ")
    }

    private func word(_ m: Bool?) -> String { m.map { $0 ? "muted" : "live" } ?? "no mute switch" }

    init(menu: NSMenu) {
        self.menu = menu
        super.init()
        item.menu = menu
        if let b = item.button {
            b.imagePosition = .imageOnly
            b.target = self
            b.action = #selector(clicked) // only fires in a call; otherwise item.menu takes the click
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        draw()
    }

    func show(_ s: BarState) {
        if s.app != state.app || s.leave != state.leave { disarm() }
        state = s
        draw()
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    // The menu bar draws template images in its own color and ignores tints, so red glyphs
    // (muted mic, leave) are drawn in color instead.
    private func red(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        img?.isTemplate = false
        return img
    }

    private func draw() {
        let armed = armTimer != nil
        if let d = drawn, d.0 == state, d.1 == armed { return }
        drawn = (state, armed)
        guard let b = item.button else { return }
        let muted = state.muted == true
        guard let app = state.app else {
            spans = []
            b.image = muted ? red("mic.slash.fill") : symbol(state.listening ? "mic.fill" : "mic")
            let words = muted ? "muted" : state.listening ? "in use" : "not in use"
            b.setAccessibilityLabel(state.mic.map { "\($0) \(words)" } ?? "Mic \(words)")
            b.toolTip = state.mic.map {
                "No call: the shortcut acts on \($0), the Mac's default mic" + (state.muted == nil ? ", which has no mute switch" : "")
            }
            item.menu = menu
            return
        }
        item.menu = nil
        var parts: [(String, Glyph)] = [("app", .text(app, nil)),
                                        ("mic", muted ? .symbol("mic.slash.fill", .systemRed) : .symbol("mic.fill", nil))]
        if let cam = state.camera {
            parts.append(("camera", .symbol(cam == true ? "video.fill" : cam == false ? "video.slash.fill" : "video", nil)))
        }
        if state.leave { parts.append(("leave", armed ? .text("Leave?", .systemRed) : .symbol("phone.down.fill", .systemRed))) }
        b.image = strip(parts)
        b.setAccessibilityLabel("\(app) call, mic \(word(state.muted))\(state.mic.map { " on \($0)" } ?? ""). Press for the call menu")
        b.toolTip = (state.mic.map { "Mic: \($0). " } ?? "")
            + "Click the mic or camera to switch it, the red phone twice to leave, the name for the menu"
    }

    // Lays the parts out side by side in one image and remembers where each one is.
    private func strip(_ parts: [(String, Glyph)]) -> NSImage {
        let height = NSStatusBar.system.thickness
        let font = NSFont.menuBarFont(ofSize: 0)
        func text(_ s: String, _ c: NSColor?) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c ?? .labelColor])
        }
        func image(_ name: String, _ c: NSColor?) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [c ?? .labelColor]))
        }
        var placed: [(Glyph, NSRect)] = []
        var x: CGFloat = 0
        spans = []
        for (name, g) in parts {
            let size: NSSize
            switch g {
            case .text(let s, let c): size = text(s, c).size()
            case .symbol(let n, let c): size = image(n, c)?.size ?? .zero
            }
            if !placed.isEmpty { x += 8 }
            let r = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: ceil(size.width), height: size.height)
            placed.append((g, r))
            spans.append((name, r.minX...r.maxX))
            x = r.maxX
        }
        // Runs when the menu bar draws it, so .labelColor comes out in the menu bar's current look.
        let img = NSImage(size: NSSize(width: x, height: height), flipped: false) { _ in
            for (g, r) in placed {
                switch g {
                case .text(let s, let c): text(s, c).draw(at: r.origin)
                case .symbol(let n, let c): image(n, c)?.draw(in: r)
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: clicks

    @objc private func clicked() {
        guard inCall else { return }
        guard let b = item.button, let e = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown].contains(e.type), e.window === b.window,
              ProcessInfo.processInfo.systemUptime - e.timestamp < 1 else { return openMenu() }
        hit(part(atX: b.convert(e.locationInWindow, from: nil).x))
    }

    // Where the strip image starts inside the button, which centers it.
    private var stripOffset: CGFloat {
        guard let b = item.button, let img = b.image else { return 0 }
        return ((b.bounds.width - img.size.width) / 2).rounded(.down)
    }

    // The part nearest to x (button coordinates), so the gaps between glyphs count too.
    private func part(atX x: CGFloat) -> String {
        let ix = x - stripOffset
        let distance = { (r: ClosedRange<CGFloat>) in max(r.lowerBound - ix, ix - r.upperBound, 0) }
        return spans.min { distance($0.x) < distance($1.x) }?.name ?? "app"
    }

    private func hit(_ name: String) {
        Log.i("bar: \(name) clicked")
        switch name {
        case "mic": onMic()
        case "camera": onCamera()
        case "leave": leave()
        default: openMenu()
        }
    }

    // Screen frames of the parts, top-left origin like Hammerspoon's, for a real-click test.
    // Also writes the item as drawn to bar.png in dir, which works with the screen locked.
    func frames(writingTo dir: URL) -> String {
        guard let b = item.button, let w = b.window else { return "no window" }
        if let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) {
            b.cacheDisplay(in: b.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("bar.png"))
        }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let button = w.convertToScreen(b.convert(b.bounds, to: nil))
        return spans.map { s in
            String(format: "%@=%.0f,%.0f,%.0f,%.0f", s.name, button.minX + stripOffset + s.x.lowerBound,
                   h - button.maxY, s.x.upperBound - s.x.lowerBound, button.height)
        }.joined(separator: " ")
    }

    // For squelch://bar?click= tests: a mouse down and up on one part, sent through AppKit's own
    // event path (window, button tracking, action), which works with the screen locked.
    // The app name is refused because its menu would hold the main thread until someone closes it.
    func click(_ name: String) -> Bool {
        guard inCall, name != "app", let b = item.button, let w = b.window,
              let s = spans.first(where: { $0.name == name }) else { return false }
        let p = b.convert(NSPoint(x: stripOffset + (s.x.lowerBound + s.x.upperBound) / 2, y: b.bounds.midY), to: nil)
        func mouse(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: t == .leftMouseDown ? 1 : 0)
        }
        guard let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) else { return false }
        NSApp.postEvent(up, atStart: false) // the button's tracking loop reads it
        NSApp.sendEvent(down)
        return true
    }

    private func openMenu() {
        item.menu = menu
        item.button?.performClick(nil) // tracks the menu until it closes
        if inCall { item.menu = nil }
    }

    private func leave() {
        if armTimer != nil {
            disarm()
            draw()
            onLeave()
            return
        }
        armTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.disarm()
            self?.draw()
        }
        draw()
    }

    private func disarm() {
        armTimer?.invalidate()
        armTimer = nil
    }
}
