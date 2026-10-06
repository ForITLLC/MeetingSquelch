// CallApps.swift: finds the call app's own mute control and presses it, so the other side sees
// the mute. Each app's own control:
//   Zoom     : Meeting > Mute audio / Unmute Audio in its menu bar (only enabled in a meeting)
//   Webex    : Participant > Mute Me / Unmute Me
//   FaceTime : Video (or Call) > Mute
//   Web calls: the Squelch browser extension, through WebBridge (Meet, Zoom, Teams, Webex in any tab)
//   Teams    : the meeting's mic button ("Mute mic" / "Unmute mic", or the label carrying ⇧ ⌘ M)
//   Slack    : "Mute microphone" / "Unmute microphone" in the huddle's toolbar
//   Discord  : the "Mute" / "Unmute" button in the voice panel
//   Meet     : "Turn off/on microphone" in the Edge or Chrome window whose tab is the Meet call,
//              for profiles without the extension
// The button apps only count while they record the mic (MicWatcher). A found button is cached and
// checked again before use, so the second press is one AX call. When the button is not reachable,
// the app's own shortcut (Teams ⌘⇧M, Slack ⌘⇧Space, Discord ⌘⇧M, Meet ⌘D) goes to its window and
// focus goes back. Everything here runs on one serial queue, never the main thread.
import AppKit
import ApplicationServices

struct Call {
    let app: String            // Zoom | Webex | FaceTime | Teams | Slack | Discord | Meet | Zoom web | ...
    let muted: Bool?           // state before the press, read from the control's label
    let control: AXUIElement?  // nil = shortcut route
    let pid: pid_t
    let window: AXUIElement?
    let shortcut: (key: CGKeyCode, flags: CGEventFlags)?
    let route: String          // menu | extension | button | cached | shortcut
}

final class CallFinder {
    static let zoomID = "us.zoom.xos"
    static let webexID = "Cisco-Systems.Spark"
    static let faceTimeID = "com.apple.FaceTime"
    static let teamsID = "com.microsoft.teams2"
    static let slackID = "com.tinyspeck.slackmacgap"
    static let discordID = "com.hnc.Discord"
    static let browserIDs = ["com.microsoft.edgemac", "com.google.Chrome"]
    var budget = 12000
    var web: WebBridge?

    private struct Cached { let pid: pid_t; let control: AXUIElement; let window: AXUIElement? }
    private var cache: [String: Cached] = [:]
    private var manualAX = Set<pid_t>()

    // MARK: label tests

    static func teamsMic(_ n: Node) -> Bool {
        let l = n.label
        let s = l.lowercased().trimmingCharacters(in: .whitespaces)
        return l.contains("⇧ ⌘ M") || l.contains("⇧⌘M") || s.hasPrefix("unmute")
            || (s.hasPrefix("mute") && s.contains("mic"))
    }

    static func slackMic(_ n: Node) -> Bool {
        let s = n.label.lowercased().trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("mute microphone") || s.hasPrefix("unmute microphone")
    }

    static func discordMic(_ n: Node) -> Bool {
        let s = n.label.lowercased().trimmingCharacters(in: .whitespaces)
        return s == "mute" || s == "unmute"
    }

    static func meetMic(_ n: Node) -> Bool {
        let s = n.label.lowercased()
        return s.contains("turn off microphone") || s.contains("turn on microphone")
    }

    static func mutedFrom(_ label: String) -> Bool? {
        let s = label.lowercased()
        if s.contains("unmute") || s.contains("turn on microphone") { return true }
        if s.contains("mute") || s.contains("turn off microphone") { return false }
        return nil
    }

    // MARK: who is recording

    static func records(_ rec: [String], _ prefix: String) -> Bool { rec.contains { $0.hasPrefix(prefix) } }

    // Teams' media engine may record under its own ID, a WebKit process or no bundle at all.
    static func teamsMaybe(_ rec: [String]) -> Bool {
        rec.contains { $0.hasPrefix("com.microsoft.teams") || $0.hasPrefix("com.apple.WebKit") || $0.isEmpty }
    }

    // Name of a call app that is recording, for the HUD when no control could be pressed.
    static func callAppRecording(_ rec: [String]) -> String? {
        if records(rec, zoomID) { return "Zoom" }
        if records(rec, webexID) { return "Webex" }
        if records(rec, "com.microsoft.teams") { return "Teams" }
        if records(rec, slackID) { return "Slack" }
        if records(rec, discordID) { return "Discord" }
        if browserIDs.contains(where: { records(rec, $0) }) { return "browser" }
        return nil
    }

    // A readable name for a process using the mic: its app, or the app a helper belongs to.
    static func appName(_ bid: String) -> String {
        let app = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleIdentifier.map { bid.hasPrefix($0) } == true
        }
        return app?.localizedName ?? (bid.isEmpty ? "an app" : bid)
    }

    static func running(_ bid: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bid).first { !$0.isTerminated }
    }

    // Chromium only builds its web accessibility tree once a client asks for it.
    func enableWebAX(_ pid: pid_t) {
        guard !manualAX.contains(pid) else { return }
        if AX.setBool(AX.app(pid), "AXManualAccessibility", true) { Log.i("AXManualAccessibility on for pid \(pid)") }
        manualAX.insert(pid)
    }

    // MARK: finders

    // Menu apps first (their mute item only works in a call), then a browser tab the extension
    // reports in a meeting, then the button apps that are recording.
    func current(_ rec: [String]) -> Call? { find(rec, search: true) }

    // Without Accessibility only the extension route works.
    func webOnly() -> Call? { webCall() }

    // Cheap read for the menu bar: menus, the extension and the cached controls only, no searching.
    func peek(_ rec: [String]) -> Call? { find(rec, search: false) }

    private func find(_ rec: [String], search: Bool) -> Call? {
        zoom() ?? webex(rec) ?? faceTime(rec) ?? webCall() ?? teams(rec, search: search)
            ?? slack(rec, search: search) ?? discord(rec, search: search) ?? meet(rec, search: search)
    }

    // Finds and caches the controls ahead of the first press (called when a call starts).
    func prefetch(_ rec: [String]) {
        let t0 = DispatchTime.now()
        let found = [teams(rec, search: true), slack(rec, search: true), discord(rec, search: true),
                     meet(rec, search: true)].compactMap { $0 }
        if !found.isEmpty {
            Log.i("prefetch \(found.map { $0.app }.joined(separator: "+")) " +
                  "via \(found.map { $0.route }.joined(separator: "+")) in \(msSince(t0)) ms")
        }
    }

    func forget(_ app: String) { cache[app] = nil }

    // A mute item in the app's menu bar. titles maps a lowercased item title to the state it
    // means; nil = a single "Mute" item whose checkmark carries the state.
    private func menuCall(_ app: String, _ bid: String, menus: Set<String>, titles: [String: Bool?]) -> Call? {
        guard let a = Self.running(bid) else { return nil }
        guard let bar = AX.value(AX.app(a.processIdentifier), kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        for item in AX.elements(bar as! AXUIElement, kAXChildrenAttribute)
        where menus.contains(AX.string(item, kAXTitleAttribute) ?? "") {
            for menu in AX.elements(item, kAXChildrenAttribute) {
                for mi in AX.elements(menu, kAXChildrenAttribute) {
                    let v = AX.values(mi, [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute])
                    guard let meaning = titles[((v[0] as? String) ?? "").lowercased()], (v[1] as? Bool) == true
                    else { continue }
                    let muted = meaning ?? !((v[2] as? String) ?? "").isEmpty
                    return Call(app: app, muted: muted, control: mi, pid: a.processIdentifier,
                                window: nil, shortcut: nil, route: "menu")
                }
            }
        }
        return nil
    }

    private func zoom() -> Call? {
        menuCall("Zoom", Self.zoomID, menus: ["Meeting"], titles: ["mute audio": false, "unmute audio": true])
    }

    // Webex and FaceTime may leave the item enabled outside a call, so they also need the app on
    // the mic, or a muted state to undo.
    private func webex(_ rec: [String]) -> Call? {
        guard let c = menuCall("Webex", Self.webexID, menus: ["Participant", "Meeting"],
                               titles: ["mute me": false, "unmute me": true]) else { return nil }
        return Self.records(rec, Self.webexID) || c.muted == true ? c : nil
    }

    private func faceTime(_ rec: [String]) -> Call? {
        guard let c = menuCall("FaceTime", Self.faceTimeID, menus: ["Video", "Call"],
                               titles: ["mute": nil, "unmute": true]) else { return nil }
        let onMic = rec.contains { $0.hasPrefix(Self.faceTimeID) || $0.hasPrefix("com.apple.avconference") || $0.isEmpty }
        return onMic || c.muted == true ? c : nil
    }

    // A browser tab the Squelch extension reports in a meeting (any tab, any window).
    private func webCall() -> Call? {
        guard let w = web?.current() else { return nil }
        return Call(app: w.app, muted: w.muted, control: nil, pid: 0, window: nil, shortcut: nil, route: "extension")
    }

    private func fromCache(_ app: String, _ test: (Node) -> Bool, titleOK: ((String) -> Bool)? = nil) -> Call? {
        guard let c = cache[app] else { return nil }
        if let n = AX.node(c.control), test(n),
           titleOK == nil || titleOK!(c.window.flatMap { AX.string($0, kAXTitleAttribute) } ?? "") {
            return Call(app: app, muted: Self.mutedFrom(n.label), control: c.control, pid: c.pid,
                        window: c.window, shortcut: nil, route: "cached")
        }
        cache[app] = nil
        return nil
    }

    private func teams(_ rec: [String], search: Bool) -> Call? {
        guard let t = Self.running(Self.teamsID), Self.teamsMaybe(rec) else { return nil }
        if let c = fromCache("Teams", Self.teamsMic) { return c }
        guard search else { return nil }
        let pid = t.processIdentifier
        enableWebAX(pid)
        let wins = AX.windows(AX.app(pid)).sorted { meetingRank($0) > meetingRank($1) }
        for w in wins {
            if let n = AX.findButton(w, budget: budget, hint: "mute", Self.teamsMic) {
                cache["Teams"] = Cached(pid: pid, control: n.element, window: w)
                return Call(app: "Teams", muted: Self.mutedFrom(n.label), control: n.element, pid: pid,
                            window: w, shortcut: nil, route: "button")
            }
        }
        // Recording but no button (toolbar hidden, compact view): Teams' own shortcut.
        if Self.records(rec, "com.microsoft.teams"), let w = wins.first {
            return Call(app: "Teams", muted: nil, control: nil, pid: pid, window: w,
                        shortcut: (46, [.maskCommand, .maskShift]), route: "shortcut") // 46 = M
        }
        return nil
    }

    // Teams meeting window titles: "Microsoft Teams Call", "Meeting compact view", "Sharing toolbar",
    // "<meeting> | Microsoft Teams"; "Main Window" is the chat window, searched last.
    private func meetingRank(_ w: AXUIElement) -> Int {
        let t = (AX.string(w, kAXTitleAttribute) ?? "").lowercased()
        if ["meeting", "call", "compact", "sharing toolbar", "controls"].contains(where: { t.contains($0) }) { return 2 }
        return t.contains("main window") ? 0 : 1
    }

    // Slack huddles. AXPress first; the shortcut when the button is not reachable.
    private func slack(_ rec: [String], search: Bool) -> Call? {
        guard let a = Self.running(Self.slackID), Self.records(rec, Self.slackID) else { return nil }
        if let c = fromCache("Slack", Self.slackMic) { return c }
        guard search else { return nil }
        let pid = a.processIdentifier
        enableWebAX(pid)
        let wins = AX.windows(AX.app(pid))
        for w in wins {
            if let n = AX.findButton(w, budget: budget, hint: "microphone", Self.slackMic) {
                cache["Slack"] = Cached(pid: pid, control: n.element, window: w)
                return Call(app: "Slack", muted: Self.mutedFrom(n.label), control: n.element, pid: pid,
                            window: w, shortcut: nil, route: "button")
            }
        }
        guard let w = wins.first else { return nil }
        return Call(app: "Slack", muted: nil, control: nil, pid: pid, window: w,
                    shortcut: (49, [.maskCommand, .maskShift]), route: "shortcut") // 49 = Space
    }

    // Discord's mute button lives in the voice panel and exists outside calls too, so a fresh
    // search needs Discord on the mic; a cached button is still used to undo a mute.
    private func discord(_ rec: [String], search: Bool) -> Call? {
        guard let a = Self.running(Self.discordID) else { return nil }
        let onMic = Self.records(rec, Self.discordID)
        if let c = fromCache("Discord", Self.discordMic) {
            let muted = c.muted == true || (AX.value(c.control!, kAXValueAttribute) as? Int) == 1
            if onMic || muted { return Call(app: "Discord", muted: muted, control: c.control, pid: c.pid,
                                            window: c.window, shortcut: nil, route: "cached") }
        }
        guard search, onMic else { return nil }
        let pid = a.processIdentifier
        enableWebAX(pid)
        let wins = AX.windows(AX.app(pid))
        for w in wins {
            if let n = AX.findButton(w, budget: budget, hint: "mute", Self.discordMic) {
                cache["Discord"] = Cached(pid: pid, control: n.element, window: w)
                let muted = Self.mutedFrom(n.label) == true || (AX.value(n.element, kAXValueAttribute) as? Int) == 1
                return Call(app: "Discord", muted: muted, control: n.element, pid: pid,
                            window: w, shortcut: nil, route: "button")
            }
        }
        guard let w = wins.first else { return nil }
        return Call(app: "Discord", muted: nil, control: nil, pid: pid, window: w,
                    shortcut: (46, [.maskCommand, .maskShift]), route: "shortcut") // 46 = M
    }

    private static func isMeetTitle(_ t: String) -> Bool { t.hasPrefix("Meet - ") || t.hasPrefix("Meet – ") }

    private func meet(_ rec: [String], search: Bool) -> Call? {
        for bid in Self.browserIDs where Self.records(rec, bid) {
            if let c = fromCache("Meet", Self.meetMic, titleOK: Self.isMeetTitle) { return c }
            guard search, let b = Self.running(bid) else { continue }
            let pid = b.processIdentifier
            enableWebAX(pid)
            for w in AX.windows(AX.app(pid)) where Self.isMeetTitle(AX.string(w, kAXTitleAttribute) ?? "") {
                if let n = AX.findButton(w, budget: budget, hint: "microphone", Self.meetMic) {
                    cache["Meet"] = Cached(pid: pid, control: n.element, window: w)
                    return Call(app: "Meet", muted: Self.mutedFrom(n.label), control: n.element, pid: pid,
                                window: w, shortcut: nil, route: "button")
                }
                return Call(app: "Meet", muted: nil, control: nil, pid: pid, window: w,
                            shortcut: (2, [.maskCommand]), route: "shortcut") // 2 = D
            }
        }
        return nil
    }

    // MARK: pressing

    func press(_ call: Call) -> Bool {
        if call.route == "extension" { return web?.toggleMute() ?? false }
        if let c = call.control { return AX.press(c) }
        guard let s = call.shortcut else { return false }
        sendShortcut(pid: call.pid, window: call.window, s.key, s.flags)
        return true
    }

    // The app's own shortcut, sent to its window; focus goes back to whatever had it.
    func sendShortcut(pid: pid_t, window: AXUIElement?, _ key: CGKeyCode, _ flags: CGEventFlags) {
        var prev: AnyObject?
        AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &prev)
        var prevPid: pid_t = 0
        if let p = prev, CFGetTypeID(p) == AXUIElementGetTypeID() { AXUIElementGetPid(p as! AXUIElement, &prevPid) }
        AX.focus(pid: pid, window: window)
        usleep(150_000)
        AX.keystroke(key, flags)
        if prevPid != 0 && prevPid != pid {
            usleep(150_000)
            AX.focus(pid: prevPid, window: nil)
        }
    }

    // MARK: debugging

    // Worst-case search cost per Teams and browser window (a test that never matches), and whether
    // the web engine answers the search predicate. For squelch://probe; presses nothing.
    func probe() -> [String] {
        var out: [String] = []
        for bid in [Self.teamsID, Self.slackID, Self.discordID] + Self.browserIDs {
            guard let a = Self.running(bid) else { continue }
            enableWebAX(a.processIdentifier)
            for w in AX.windows(AX.app(a.processIdentifier)) {
                let t0 = DispatchTime.now()
                _ = AX.findButton(w, budget: budget, hint: "mute") { _ in false }
                let ms = msSince(t0)
                var engine = "no web area"
                if let web = firstWebArea(w) {
                    if case .unsupported = AX.search(web, key: "AXButtonSearchKey", text: nil, limit: 5, { _ in false }) {
                        engine = "tree walk (no search predicate)"
                    } else {
                        engine = "engine search"
                    }
                }
                let title = (AX.string(w, kAXTitleAttribute) ?? "").prefix(40)
                out.append("\(bid) [\(title)] full search \(ms) ms, \(engine)")
            }
        }
        return out
    }

    private func firstWebArea(_ root: AXUIElement) -> AXUIElement? {
        var queue = [root]; var i = 0
        while i < queue.count && i < 400 {
            let e = queue[i]; i += 1
            if AX.string(e, kAXRoleAttribute) == "AXWebArea" { return e }
            queue += AX.elements(e, kAXChildrenAttribute)
        }
        return nil
    }

    // Every mic-looking control in Teams and browser windows, for squelch://dump (read-only).
    func dump() -> [String] {
        var out: [String] = []
        for bid in [Self.teamsID, Self.slackID, Self.discordID] + Self.browserIDs {
            guard let a = Self.running(bid) else { continue }
            enableWebAX(a.processIdentifier)
            for w in AX.windows(AX.app(a.processIdentifier)) {
                let title = AX.string(w, kAXTitleAttribute) ?? ""
                out += AX.dump(w, budget: budget).map { "\(bid) [\(title)] \($0)" }
            }
        }
        return out
    }
}
