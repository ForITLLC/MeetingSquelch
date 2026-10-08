// AppDelegate.swift: menu bar item, hotkey, HUD and the presses.
// A press goes to the call app when one is found (CallApps.swift, WebBridge.swift for browser
// tabs), otherwise to the default mic's own mute switch, the one SoundSource shows (SystemMic.swift).
// In a call the menu bar shows the call's mic, camera and leave buttons (CallBar.swift, Controls.swift),
// and names the mic the call app records from, which may not be the Mac's default input (MicPick.swift).
// The app's own state is read every second in a call and every 2 s otherwise, so a mute or camera
// change made inside the call app shows up here too.
// All Accessibility work runs on axQueue; the main thread only draws. Status for scripts:
// ~/Library/Application Support/Squelch/status.json, written when something changes (at least every 10 s).
// Paired iPhones press through RemoteServer.swift (docs/remote-protocol.md). Its port (47214, on the local
// network) is closed until the user turns the remote on: Pair iPhone… turns it on, Turn Off iPhone Remote
// turns it off (defaults key remote). A Mac that paired a phone before the remote was opt-in stays on.
// URLs: squelch://toggle  squelch://status  squelch://prefetch  squelch://dump  squelch://probe
// With `defaults write io.forit.squelch testURLs -bool true` also camera, share, leave, front (tests only:
// any web page can ask the browser to open a URL, so these stay off). Shortcuts uses the App Intents instead
// (Intents.swift).
import AppKit

struct PressReport {
    var source = ""
    var app = "system"   // Zoom | Webex | FaceTime | Teams | Slack | Discord | Meet | ... | system
    var route = ""
    var ok = false
    var muted: Bool?     // state after the press; nil = toggled but unknown
    var device = ""
    var warn: String?
    var ms = 0

    var line: String {
        let state = muted.map { $0 ? "muted" : "live" } ?? "toggled"
        return "press \(source) -> \(app) via \(route) ok=\(ok) \(state)" +
            (device.isEmpty ? "" : " [\(device)]") + (warn.map { " (\($0))" } ?? "") + " in \(ms) ms"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let watcher = MicWatcher()
    let micState = MicStateWatcher()
    let finder = CallFinder()
    lazy var web = WebBridge(port: UInt16(clamping: UserDefaults.standard.object(forKey: "extensionPort") as? Int ?? 47213))
    lazy var remote = RemoteServer(port: UInt16(clamping: UserDefaults.standard.object(forKey: "remotePort") as? Int ?? Int(Remote.defaultPort)),
                                   dir: supportDir)
    lazy var pairWindow = PairWindow(remote: remote)
    var remoteOn = false
    let axQueue = DispatchQueue(label: "io.forit.squelch.ax", qos: .userInteractive)
    lazy var controls = ControlFinder(finder: finder)
    lazy var hud = HUD()
    var bar: CallBar!
    var hotKey: HotKey?
    var oldHotKey: HotKey?
    var trusted = false
    var shownCall: String?
    var shownMuted: Bool?
    var shownMic = ""              // the default input: what a press with no call acts on
    var shownCallMic: String?      // in a call: the mic the call app records from (MicPick)
    var shownInputs: [MicUse] = [] // every recording process and its input, for status.json
    var shownControls: [Action: Control] = [:]
    var lastRefind = Date.distantPast // the last search for buttons that went stale mid-call (refresh)
    var lastBlindSearch = Date.distantPast // the last search for the mute button of a call on its shortcut (refresh)
    var lastPress: [String: Any] = [:]
    var tick = 0
    var lastStatus = Data()
    var lastStatusAt = Date.distantPast
    let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "Toggle Mute", action: #selector(menuToggle), keyEquivalent: "")
    let cameraItem = NSMenuItem(title: "Camera", action: #selector(menuCamera), keyEquivalent: "")
    let shareItem = NSMenuItem(title: "Share Screen", action: #selector(menuShare), keyEquivalent: "")
    let frontItem = NSMenuItem(title: "Show Call Window", action: #selector(menuFront), keyEquivalent: "")
    let leaveItem = NSMenuItem(title: "Leave Call", action: #selector(menuLeave), keyEquivalent: "")
    let callSeparator = NSMenuItem.separator()
    let keyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let axItem = NSMenuItem(title: "", action: #selector(openAXSettings), keyEquivalent: "")
    let pairItem = NSMenuItem(title: "Pair iPhone…", action: #selector(pairPhone), keyEquivalent: "")
    let phonesItem = NSMenuItem(title: "Paired iPhones", action: nil, keyEquivalent: "")
    let remoteOffItem = NSMenuItem(title: "Turn Off iPhone Remote", action: #selector(turnOffRemote), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Squelch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        AX.setGlobalTimeout(0.6)
        let menu = NSMenu()
        menu.delegate = self
        stateItem.isEnabled = false
        for i in [toggleItem, cameraItem, shareItem, frontItem, leaveItem, axItem, pairItem, remoteOffItem, loginItem] {
            i.target = self
        }
        phonesItem.submenu = NSMenu()
        keyItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(toggleItem)
        for i in [cameraItem, shareItem, frontItem, callSeparator, leaveItem] { menu.addItem(i) }
        menu.addItem(keyItem)
        menu.addItem(.separator())
        menu.addItem(pairItem)
        menu.addItem(phonesItem)
        menu.addItem(remoteOffItem)
        menu.addItem(.separator())
        menu.addItem(axItem)
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Squelch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.autoenablesItems = false
        bar = CallBar(menu: menu)
        bar.onMic = { [weak self] in self?.toggle(source: "bar") }
        bar.onCamera = { [weak self] in self?.act(.camera, source: "bar") }
        bar.onLeave = { [weak self] in self?.act(.leave, source: "bar") }

        LoginItem.setUpOnce()
        trusted = AX.trusted()
        if !trusted { _ = AX.trusted(prompt: true) }
        watcher.onChange = { [weak self] rec in self?.recordingChanged(rec) }
        watcher.start()
        micState.onChange = { [weak self] in self?.refresh() }
        micState.start()
        finder.web = web
        web.onChange = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        web.start()
        if let on = UserDefaults.standard.object(forKey: "remote") as? Bool {
            remoteOn = on
        } else if RemoteServer.hasPairedPhone(dir: supportDir) {
            remoteOn = true
            UserDefaults.standard.set(true, forKey: "remote")
            Log.i("remote: on, a phone was paired before the remote was opt-in")
        }
        if remoteOn { startRemote() } else { Log.i("remote: off (Pair iPhone… turns it on)") }
        let custom = UserDefaults.standard.string(forKey: "hotkey")
        let spec = custom ?? "ctrl+opt+cmd+m"
        hotKey = HotKey(spec: spec) { [weak self] in self?.toggle(source: "hotkey") }
        if hotKey == nil {
            Log.i("hotkey spec '\(spec)' not understood; set it with: defaults write io.forit.squelch hotkey ctrl+opt+cmd+m")
        }
        hotKey?.register()
        // Until 2026-10-08 the default also needed Shift, because Tinycast's Smart Mute held Control + Option +
        // Command + M. That chord still mutes, unshown, for anything that sends all four modifiers.
        if custom == nil {
            oldHotKey = HotKey(spec: "ctrl+opt+shift+cmd+m") { [weak self] in self?.toggle(source: "hotkey") }
            oldHotKey?.register()
        }
        keyItem.title = hotKey.map { "Shortcut: \($0.display)" } ?? "No shortcut"
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tick += 1
            if self.shownCall != nil || self.tick % 2 == 0 { self.refresh() }
        }
        Log.i("Squelch \(version) started (pid \(getpid())), shortcut \(hotKey?.display ?? "none"), " +
              "Accessibility \(trusted ? "granted" : "NOT granted"), SoundSource \(SoundSource.running ? "running" : "not running")")
        refresh()
        recordingChanged(watcher.recording)
    }

    // MARK: pressing

    @objc func menuToggle() { toggle(source: "menu") }

    func toggle(source: String, done: ((PressReport) -> Void)? = nil) {
        let t0 = DispatchTime.now()
        let rec = watcher.recording
        let procs = watcher.objects
        let trusted = AX.trusted()
        let finder = self.finder
        let web = self.web
        axQueue.async { [weak self] in
            var r = PressReport(source: source)
            // The extension route needs no Accessibility; everything else in CallFinder does.
            if var call = trusted ? finder.current(rec) : finder.webOnly() {
                let mics = MicPick.callInputs(call.app, MicWatcher.inputs(procs))
                SystemMic.releaseForCall(mics.map { $0.device })
                r.device = MicPick.label(mics) ?? ""
                // Once Teams has ignored an AX press, the next ones skip it: ⌘⇧M straight away, read from the
                // button (2026-10-07 15:56Z to 10-08 19:02Z, Teams ignored 19 presses of 19; each cost ~1 s).
                let direct = call.app == "Teams" && call.control != nil && call.muted != nil && finder.teamsIgnoresPress
                var ok: Bool
                if direct {
                    finder.sendShortcut(pid: call.pid, window: call.window, 46, [.maskCommand, .maskShift]) // 46 = M
                    ok = true
                } else {
                    ok = finder.press(call)
                }
                if !ok && call.route == "cached" { // the control went stale: search once more
                    finder.forget(call.app)
                    if let again = finder.current(rec) { call = again; ok = finder.press(again) }
                }
                r.app = call.app; r.route = direct ? "\(call.route)+shortcut" : call.route; r.ok = ok
                r.muted = call.muted.map { !$0 }
                if ok && call.route == "extension", let before = call.muted {
                    r.muted = web.awaitMuted(not: before, timeout: 0.6) // the tab reports back
                }
                // Teams can ignore an AX press and keep its label (2026-10-06 18:34Z on: six presses
                // "worked", Teams' own log shows none). Read the button back; if it didn't flip, send
                // Teams' ⌘⇧M and read again. A press that never shows up is reported as failed.
                if ok && call.app == "Teams" && call.control != nil, let before = call.muted {
                    var after = finder.awaitFlip(call, from: before, timeout: direct ? 0.8 : 0.7)
                    if !direct { finder.teamsIgnoresPress = after != !before }
                    if after != !before && !direct {
                        Log.i("press: Teams kept \(before ? "muted" : "live") after the \(call.route) press; sending ⌘⇧M")
                        finder.forget("Teams")
                        finder.sendShortcut(pid: call.pid, window: call.window, 46, [.maskCommand, .maskShift]) // 46 = M
                        r.route += "+shortcut"
                        after = finder.awaitFlip(call, from: before, timeout: 0.8)
                        // The old element may be gone (Teams reloads its window): look once more.
                        if after != !before, let again = finder.current(rec), again.app == "Teams",
                           let m = again.muted { after = m }
                        // The bar only reads cached buttons: cache Teams' again, or the bar shows no call
                        // for the rest of it (2026-10-07 15:56Z, a bare white mic over a muted Teams call).
                        finder.prefetch(rec)
                    } else if after != !before {
                        // The direct ⌘⇧M didn't show either. The element may be gone: look once more.
                        if let again = finder.current(rec), again.app == "Teams", let m = again.muted { after = m }
                        finder.prefetch(rec)
                    }
                    if after == !before { r.muted = after } else {
                        r.ok = false
                        r.warn = "Teams did not change"
                    }
                }
            } else {
                let m = SystemMic.toggle()
                r.route = SoundSource.running ? "soundsource" : "coreaudio"
                r.ok = m.ok; r.muted = m.muted; r.device = m.name
                if let app = CallFinder.callAppRecording(rec) {
                    r.warn = trusted ? "\(app) is recording but its mute control was not found" : "Accessibility is off"
                }
            }
            r.ms = msSince(t0)
            Log.i(r.line)
            DispatchQueue.main.async {
                self?.pressed(r)
                done?(r)
            }
        }
    }

    func pressed(_ r: PressReport) {
        let state = r.muted.map { $0 ? "muted" : "live" }
        if r.app != "system" {
            let on = r.device.isEmpty ? "" : " · \(r.device)" // the mic the call records from
            if !r.ok {
                hud.show(symbol: "exclamationmark.triangle.fill", "\(r.app) mute failed", tint: .systemYellow)
            } else if let m = r.muted {
                hud.show(symbol: m ? "mic.slash.fill" : "mic.fill", "\(r.app) \(state!)\(on)", tint: m ? .systemRed : nil)
            } else {
                hud.show(symbol: "arrow.triangle.2.circlepath", "\(r.app) mic toggled\(on)")
            }
            shownCall = r.app
            shownMuted = r.muted
            if !r.device.isEmpty { shownCallMic = r.device }
        } else if r.muted == nil {
            // The mic has no mute switch. With nothing listening there is nothing to mute.
            let users = micUsers()
            if users.isEmpty {
                hud.show(symbol: "mic", "No call, nothing is using the mic", seconds: 1.5)
            } else {
                hud.show(symbol: "exclamationmark.triangle.fill",
                         "\(r.device) has no mute switch: \(users.joined(separator: ", ")) can still hear you",
                         tint: .systemYellow, seconds: 2.5)
            }
        } else if let m = r.muted {
            let extra = r.warn != nil ? " (whole Mac)" : ""
            // Names the device, so muting the default (dictation) mic with no call is never a surprise.
            let mic = r.device.isEmpty ? "Mic" : r.device
            hud.show(symbol: m ? "mic.slash.fill" : "mic.fill", "\(mic) \(state!)\(extra)", tint: m ? .systemRed : nil,
                     seconds: r.warn != nil ? 2 : 1.1)
            shownCall = nil
            shownMuted = m
            checkStuck(r, m)
        }
        lastPress = ["at": ISO8601DateFormatter().string(from: Date()), "source": r.source, "app": r.app,
                     "route": r.route, "ok": r.ok, "result": state ?? "toggled", "ms": r.ms,
                     "device": r.device, "warn": r.warn ?? ""]
        render()
        // Teams and Meet relabel the button a moment after the press; read it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    // Camera, sharing and leave, in whichever call is up.
    func act(_ action: Action, source: String, done: ((_ ok: Bool, _ on: Bool?, _ why: String?) -> Void)? = nil) {
        let t0 = DispatchTime.now()
        let rec = watcher.recording
        let trusted = AX.trusted()
        let finder = self.finder
        let controls = self.controls
        axQueue.async { [weak self] in
            guard let call = trusted ? (finder.peek(rec) ?? finder.current(rec)) : finder.webOnly() else {
                Log.i("\(action.rawValue) \(source): no call")
                DispatchQueue.main.async {
                    self?.hud.show(symbol: "questionmark.circle", "No call", seconds: 1.1)
                    done?(false, nil, "no call")
                }
                return
            }
            let found = controls.controls(for: call, search: false)[action] ?? controls.controls(for: call, search: true)[action]
            guard let c = found else {
                Log.i("\(action.rawValue) \(source) -> \(call.app): no \(action.rawValue) control found")
                DispatchQueue.main.async {
                    self?.hud.show(symbol: "exclamationmark.triangle.fill", "\(call.app): no \(action.rawValue) button found", tint: .systemYellow)
                    done?(false, nil, "no \(action.rawValue) button in \(call.app)")
                }
                return
            }
            let ok = controls.press(c, call: call)
            let after = ok && action != .leave ? controls.readBack(c, call: call) : nil
            let ms = msSince(t0)
            let state = after.map { $0 ? "on" : "off" } ?? (ok ? "toggled" : "failed")
            Log.i("\(action.rawValue) \(source) -> \(call.app) via \(c.route) ok=\(ok) \(state) in \(ms) ms")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.acted(action, app: call.app, ok: ok, on: after)
                done?(ok, after, ok ? nil : "\(action.rawValue) failed")
                self.lastPress = ["at": ISO8601DateFormatter().string(from: Date()), "source": source, "app": call.app,
                                  "action": action.rawValue, "route": c.route, "ok": ok, "result": state, "ms": ms]
                self.refresh()
            }
        }
    }

    func acted(_ action: Action, app: String, ok: Bool, on: Bool?) {
        guard ok else {
            hud.show(symbol: "exclamationmark.triangle.fill", "\(app) \(action.rawValue) failed", tint: .systemYellow)
            return
        }
        switch action {
        case .camera:
            hud.show(symbol: on == false ? "video.slash.fill" : "video.fill",
                     "\(app) camera \(on.map { $0 ? "on" : "off" } ?? "toggled")")
        case .share:
            hud.show(symbol: "rectangle.on.rectangle", "\(app) sharing \(on.map { $0 ? "started" : "stopped" } ?? "toggled")")
        case .leave:
            hud.show(symbol: "phone.down.fill", "Left the \(app) call", tint: .systemRed)
        }
    }

    // SoundSource's per-device Mute lock flips the switch straight back; say so instead of
    // leaving the icon wrong.
    func checkStuck(_ r: PressReport, _ wanted: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, let now = SystemMic.state().muted, now != wanted else { return }
            let who = SoundSource.running ? "SoundSource's Mute lock" : "another app"
            Log.i("system mic \(r.device) went back to \(now ? "muted" : "live") after the press: \(who)")
            self.hud.show(symbol: "lock.fill", "\(who) kept \(r.device) \(now ? "muted" : "live")", tint: .systemYellow, seconds: 2.5)
            self.refresh()
        }
    }

    // MARK: state

    func recordingChanged(_ rec: [String]) {
        refresh()
        let buttonApps = [CallFinder.slackID, CallFinder.discordID] + CallFinder.browserIDs
        guard trusted, CallFinder.teamsMaybe(rec) || buttonApps.contains(where: { CallFinder.records(rec, $0) })
        else { return }
        // Find the controls before the first press; the meeting UI can take a few seconds to load.
        for delay in [1.5, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.prefetch() }
        }
    }

    // quiet: log only what changed for the better (the search every 10 s while a call has no mute button).
    func prefetch(quiet: Bool = false) {
        let rec = watcher.recording
        let finder = self.finder
        let controls = self.controls
        let trusted = self.trusted
        axQueue.async { [weak self] in
            if trusted { finder.prefetch(rec, quiet: quiet) }
            guard let call = trusted ? finder.peek(rec) : finder.webOnly() else { return }
            let t0 = DispatchTime.now()
            let found = controls.controls(for: call, search: true)
            if !quiet || call.route != "shortcut" {
                Log.i("controls \(call.app): " + Action.allCases.map { a in "\(a.rawValue) \(found[a]?.route ?? "none")" }
                    .joined(separator: ", ") + " in \(msSince(t0)) ms")
            }
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func refresh() {
        let now = AX.trusted()
        if now != trusted {
            trusted = now
            Log.i("Accessibility \(now ? "granted" : "revoked")")
            if now { prefetch() }
        }
        let rec = watcher.recording
        let procs = watcher.objects
        let finder = self.finder
        let controls = self.controls
        axQueue.async { [weak self] in
            let call = now ? finder.peek(rec) : finder.webOnly()
            let ctl = call.map { controls.controls(for: $0, search: false) } ?? [:]
            if call == nil { controls.reset() }
            let mic = SystemMic.state()
            let inputs = MicWatcher.inputs(procs)
            let callMic = call.flatMap { MicPick.label(MicPick.callInputs($0.app, inputs)) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let started = call != nil && call?.app != self.shownCall
                // The call vanished but a call app is still on the mic: its cached button went stale
                // (Teams reloads its window) or a press dropped it. Search while the window settles.
                let lost = call == nil && now && self.shownCall != nil && CallFinder.callAppRecording(rec) != nil
                // The call stayed but buttons the bar showed went stale (Teams rebuilt its toolbar): search again,
                // at most every 20 s in case a window keeps rebuilding.
                let stale = call == nil || started ? [] : self.shownControls.keys.filter { ctl[$0] == nil }
                self.shownCall = call?.app
                self.shownMuted = call != nil ? (call!.muted ?? self.shownMuted) : mic.muted
                self.shownMic = mic.name
                self.shownCallMic = callMic
                self.shownInputs = inputs
                self.shownControls = ctl
                self.render()
                // A call just showed up: find its camera and leave buttons while the user talks.
                if started {
                    for delay in [0.5, 5.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            if self?.shownCall != nil { self?.prefetch() }
                        }
                    }
                }
                if lost {
                    Log.i("bar: the call's control is gone while \(CallFinder.callAppRecording(rec)!) records; searching")
                    for delay in [0.0, 2.0, 6.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            if self?.shownCall == nil { self?.prefetch() }
                        }
                    }
                }
                // A call with only its shortcut (no mute button found) shows no mute state, and nothing else
                // searches again while it lasts: look every 10 s in case its meeting window is back
                // (2026-10-08 19:03Z, the last minute of a Teams call without it).
                if call?.route == "shortcut", !started, Date().timeIntervalSince(self.lastBlindSearch) > 10 {
                    self.lastBlindSearch = Date()
                    self.prefetch(quiet: true)
                }
                if !stale.isEmpty, Date().timeIntervalSince(self.lastRefind) > 20 {
                    self.lastRefind = Date()
                    Log.i("bar: \(call!.app) " + stale.map(\.rawValue).sorted().joined(separator: ", ") + " went stale; searching")
                    for delay in [0.0, 2.0, 6.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            if self?.shownCall != nil { self?.prefetch() }
                        }
                    }
                }
            }
        }
    }

    // Apps using the mic. SoundSource's audio daemon reads it on its own (meters, effects) and is
    // listed next to the app when it processes one, so it never counts by itself.
    var listeners: [String] { watcher.recording.filter { $0 != "com.rogueamoeba.arkaudiod" } }

    func micUsers() -> [String] { Set(listeners.map(CallFinder.appName)).sorted() }

    func render() {
        var s = BarState(app: shownCall, muted: shownMuted)
        s.listening = !listeners.isEmpty
        s.mic = shownCall != nil ? shownCallMic : (shownMic.isEmpty ? nil : shownMic)
        if shownCall != nil {
            s.camera = shownControls[.camera].map { $0.on }
            s.leave = shownControls[.leave] != nil
        }
        bar.show(s)
        if remoteOn {
            let inCall = shownCall != nil
            remote.publish(RemoteMessage(t: "state", app: shownCall, muted: shownMuted,
                                         camera: inCall ? shownControls[.camera]?.on : nil,
                                         share: inCall ? shownControls[.share]?.on : nil,
                                         mic: inCall ? nil : shownMic))
        }
        writeStatus()
    }

    func stateText() -> String {
        if let c = shownCall {
            var t = "\(c) call · \(shownMuted.map { $0 ? "muted" : "live" } ?? "unknown")"
            if let m = shownCallMic { t += " · \(m)" }
            if let cam = shownControls[.camera]?.on { t += cam ? " · camera on" : " · camera off" }
            if shownControls[.share]?.on == true { t += " · sharing" }
            return t
        }
        let word = shownMuted.map { $0 ? "muted" : "live" } ?? "has no mute switch"
        let users = micUsers()
        let use = users.isEmpty ? "not in use" : "in use by " + users.joined(separator: ", ")
        return "No call · \(shownMic) (default mic) · \(word) · \(use)" + (SoundSource.running ? " · SoundSource" : "")
    }

    func menuWillOpen(_ menu: NSMenu) {
        stateItem.title = stateText()
        axItem.title = trusted ? "Accessibility: granted" : "Grant Accessibility…"
        axItem.isEnabled = !trusted
        loginItem.isHidden = LoginItem.launchAgent
        loginItem.state = LoginItem.status == .enabled ? .on : .off
        let inCall = shownCall != nil
        toggleItem.title = inCall ? (shownMuted == true ? "Unmute" : "Mute") : "Toggle Mute"
        let cam = shownControls[.camera], share = shownControls[.share]
        cameraItem.isHidden = cam == nil
        cameraItem.title = cam?.on == true ? "Turn Camera Off" : cam?.on == false ? "Turn Camera On" : "Camera On/Off"
        shareItem.isHidden = share == nil
        shareItem.title = share?.on == true ? "Stop Sharing" : "Share Screen"
        frontItem.isHidden = !inCall
        frontItem.title = "Show \(shownCall ?? "Call") Window"
        leaveItem.isHidden = shownControls[.leave] == nil
        leaveItem.title = "Leave \(shownCall ?? "") Call"
        callSeparator.isHidden = !inCall
        if inCall { prefetch() } // a button missing now is there next time the menu opens
        let phones = remoteOn ? remote.phones : []
        phonesItem.isHidden = phones.isEmpty
        remoteOffItem.isHidden = !remoteOn
        phonesItem.submenu?.removeAllItems()
        for p in phones {
            let i = NSMenuItem(title: "Remove \(p.name)", action: #selector(removePhone(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.device
            phonesItem.submenu?.addItem(i)
        }
    }

    func writeStatus() {
        let remoteStatus: [String: Any] = remoteOn ? remote.status : ["off": true]
        let d: [String: Any] = [
            "pid": Int(getpid()), "version": version,
            "accessibility": trusted, "hotkey": hotKey?.display ?? "", "hotkeyRegistered": hotKey?.registered ?? false,
            "soundSource": SoundSource.running, "web": web.status, "remote": remoteStatus, "openAtLogin": LoginItem.summary,
            "recording": watcher.recording, "call": shownCall ?? NSNull(), "muted": shownMuted ?? NSNull(),
            "mic": shownMic, "state": stateText(), "lastPress": lastPress, "bar": bar.summary,
            "callMic": (shownCall != nil ? shownCallMic : nil) ?? NSNull(),
            "inputs": shownInputs.map { "\($0.bundleID.isEmpty ? "(no-bundle)" : $0.bundleID): \($0.name)" },
            "controls": Dictionary(uniqueKeysWithValues: shownControls.map { k, c in
                (k.rawValue, "\(c.route)" + (c.on.map { $0 ? " on" : " off" } ?? ""))
            }),
        ]
        // Only write when something changed, plus a heartbeat every 10 s.
        guard let body = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
        if body == lastStatus && Date().timeIntervalSince(lastStatusAt) < 10 { return }
        lastStatus = body
        lastStatusAt = Date()
        var full = d
        full["updated"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: supportDir.appendingPathComponent("status.json"), options: .atomic)
    }

    // MARK: menu and URL actions

    @objc func openAXSettings() {
        _ = AX.trusted(prompt: true)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc func toggleLogin() { LoginItem.set(LoginItem.status != .enabled) }
    @objc func menuCamera() { act(.camera, source: "menu") }
    @objc func menuShare() { act(.share, source: "menu") }
    @objc func menuLeave() { act(.leave, source: "menu") }

    @objc func menuFront() { front() }

    @objc func pairPhone() {
        if !remoteOn { setRemote(true) }
        pairWindow.show()
    }

    @objc func turnOffRemote() { setRemote(false) }

    func startRemote() {
        remote.onPress = { [weak self] what, reply in self?.remotePress(what, source: "iphone", reply) }
        remote.start()
    }

    // The user's choice, kept in defaults key remote. Off closes the port; the paired phones stay paired.
    func setRemote(_ on: Bool) {
        guard on != remoteOn else { return }
        remoteOn = on
        UserDefaults.standard.set(on, forKey: "remote")
        if on {
            Log.i("remote: turned on from the menu")
            startRemote()
        } else {
            Log.i("remote: turned off from the menu")
            pairWindow.close()
            remote.stop()
        }
        writeStatus()
    }

    @objc func removePhone(_ sender: NSMenuItem) {
        if let device = sender.representedObject as? String { remote.remove(device: device) }
    }

    // A press from a paired iPhone or a Shortcuts intent: the same routes as the shortcut and the menu bar.
    func remotePress(_ what: String, source: String, _ reply: @escaping (RemoteMessage) -> Void) {
        switch what {
        case "mic":
            toggle(source: source) { r in
                reply(RemoteMessage(t: "done", what: what, app: r.app == "system" ? nil : r.app, muted: r.muted,
                                    ok: r.ok, why: r.warn))
            }
        case "front":
            front()
            reply(RemoteMessage(t: "done", what: what, ok: shownCall != nil, why: shownCall == nil ? "no call" : nil))
        default:
            guard let a = Action(rawValue: what) else {
                reply(RemoteMessage(t: "done", what: what, ok: false, why: "unknown action"))
                return
            }
            act(a, source: source) { ok, on, why in
                reply(RemoteMessage(t: "done", what: what, camera: a == .camera ? on : nil,
                                    share: a == .share ? on : nil, ok: ok, why: why))
            }
        }
    }

    func front() {
        let rec = watcher.recording
        let finder = self.finder
        let controls = self.controls
        let trusted = self.trusted
        axQueue.async {
            if let call = trusted ? finder.peek(rec) : finder.webOnly() { controls.bringToFront(call) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            switch u.host ?? "" {
            case "toggle": toggle(source: "url")
            case "status": refresh()
            case "prefetch": prefetch()
            case "dump":
                let finder = self.finder
                let file = supportDir.appendingPathComponent("dump.txt")
                axQueue.async {
                    let lines = finder.dump()
                    try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
                    Log.i("dump: \(lines.count) mic-looking controls written to \(file.path)")
                }
            case "probe":
                let finder = self.finder
                axQueue.async { for l in finder.probe() { Log.i("probe \(l)") } }
            case "camera", "share", "leave", "front", "bar":
                guard UserDefaults.standard.bool(forKey: "testURLs") else {
                    Log.i("refused \(u.absoluteString): test URLs are off")
                    continue
                }
                if u.host == "bar" {
                    let name = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "click" }?.value ?? ""
                    if name == "frames" { Log.i("test: bar frames \(bar.frames(writingTo: supportDir))"); continue }
                    Log.i("test: bar click \(name) -> \(bar.click(name) ? "clicked" : "no such button")")
                } else if let a = Action(rawValue: u.host ?? "") {
                    act(a, source: "url")
                } else {
                    front()
                }
            default: Log.i("unknown URL \(u.absoluteString)")
            }
        }
    }
}
