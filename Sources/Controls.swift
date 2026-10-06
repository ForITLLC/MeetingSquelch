// Controls.swift: the in-call buttons beyond the mic (camera, sharing, leave), for the menu bar
// strip and its menu. The labels are the apps' own:
//   Zoom    : Meeting > Start Video / Stop Video, Start Share / Stop Share; the "Leave" or "End"
//             button in the "Zoom Meeting" / "Meeting Controls" window, then "Leave Meeting" in
//             the confirmation (never "End Meeting for All")
//   Webex   : "Start video" / "Stop video", "Share" / "Stop sharing" buttons
//   Teams   : "Turn camera off" / "Turn camera on", "Share content" / "Stop sharing", "Leave"
//   Slack   : "Turn on camera" / "Turn off camera", "Share your screen" / "Stop sharing screen", "Leave Huddle"
//   Discord : "Turn on/off camera", "Share your screen" / "Stop streaming", "Disconnect"
//   Meet    : "Turn on/off camera", "Share screen" / "Stop presenting", "Leave call"
// Browser calls go through the Squelch extension (WebBridge.swift: camera, share, leave, front).
// FaceTime gets the mic only. Everything here runs on the AX queue.
import AppKit
import ApplicationServices

enum Action: String, CaseIterable {
    case camera, share, leave
}

struct Control {
    let action: Action
    let on: Bool?               // camera on / presenting; nil = unknown (shortcut) or not a state (leave)
    let element: AXUIElement?   // nil = extension or shortcut route
    let pid: pid_t
    let window: AXUIElement?
    let shortcut: (key: CGKeyCode, flags: CGEventFlags)?
    let route: String           // menu | extension | button | cached | shortcut
}

struct Rule {
    enum Kind { case exact, prefix, contains }
    let kind: Kind
    let text: String
    let on: Bool?

    static func exact(_ t: String, _ on: Bool? = nil) -> Rule { Rule(kind: .exact, text: t, on: on) }
    static func prefix(_ t: String, _ on: Bool? = nil) -> Rule { Rule(kind: .prefix, text: t, on: on) }
    static func contains(_ t: String, _ on: Bool? = nil) -> Rule { Rule(kind: .contains, text: t, on: on) }

    func matches(title: String, desc: String) -> Bool {
        let parts = [title, desc].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        switch kind {
        case .exact: return parts.contains(text)
        case .prefix: return parts.contains { $0.hasPrefix(text) }
        case .contains: return (parts[0] + " " + parts[1]).contains(text)
        }
    }

    // The first matching rule decides; nil = no match.
    static func first(_ rules: [Rule], _ n: Node) -> Rule? { rules.first { $0.matches(title: n.title, desc: n.desc) } }
}

private struct Spec {
    enum Windows { case micWindow, titled([String]), all }
    var buttons: [Action: [Rule]] = [:]
    var hints: [Action: String] = [:]          // narrows the web engine's search
    var menus: Set<String> = []
    var menuRules: [Action: [Rule]] = [:]
    var shortcuts: [Action: (CGKeyCode, CGEventFlags)] = [:]
    var windows: Windows = .all
}

final class ControlFinder {
    let finder: CallFinder
    private var app = ""
    private var cache: [Action: Control] = [:]
    private let budget = 12000

    init(finder: CallFinder) { self.finder = finder }

    private static let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
    private static let specs: [String: Spec] = [
        "Zoom": Spec(buttons: [.leave: [.exact("leave"), .exact("end")]],
                     menus: ["Meeting"],
                     menuRules: [.camera: [.exact("stop video", true), .exact("start video", false)],
                                 .share: [.exact("stop share", true), .exact("start share", false)]],
                     windows: .titled(["zoom meeting", "meeting controls"])),
        "Webex": Spec(buttons: [.camera: [.prefix("stop video", true), .prefix("start video", false)],
                                .share: [.prefix("stop sharing", true), .exact("share", false)],
                                .leave: [.exact("leave"), .prefix("leave meeting"), .prefix("leave call")]],
                      hints: [.camera: "video", .share: "shar", .leave: "leave"]),
        "Teams": Spec(buttons: [.camera: [.contains("turn camera off", true), .contains("turn camera on", false)],
                                .share: [.contains("stop sharing", true), .contains("share content", false), .exact("share", false)],
                                .leave: [.exact("leave"), .prefix("leave ("), .exact("hang up")]],
                      hints: [.camera: "camera", .share: "shar", .leave: "leave"],
                      shortcuts: [.camera: (31, cmdShift), .share: (14, cmdShift), .leave: (4, cmdShift)], // O, E, H
                      windows: .micWindow),
        "Slack": Spec(buttons: [.camera: [.contains("turn off camera", true), .contains("turn on camera", false)],
                                .share: [.contains("stop sharing screen", true), .contains("share your screen", false)],
                                .leave: [.contains("leave huddle")]],
                      hints: [.camera: "camera", .share: "screen", .leave: "leave"]),
        "Discord": Spec(buttons: [.camera: [.contains("turn off camera", true), .contains("turn on camera", false)],
                                  .share: [.contains("stop streaming", true), .contains("share your screen", false)],
                                  .leave: [.exact("disconnect")]],
                        hints: [.camera: "camera", .share: "screen", .leave: "disconnect"]),
        "Meet": Spec(buttons: [.camera: [.contains("turn off camera", true), .contains("turn on camera", false)],
                               .share: [.contains("stop presenting", true), .contains("share screen", false),
                                        .contains("present now", false)],
                               .leave: [.contains("leave call")]],
                     hints: [.camera: "camera", .leave: "leave"],
                     shortcuts: [.camera: (14, [.maskCommand])], // E
                     windows: .micWindow),
    ]

    private static let extensionCommands: [Action: String] = [
        .camera: "camera", .share: "share", .leave: "leave",
    ]

    func reset() {
        app = ""
        cache = [:]
    }

    // The call's other controls. search=false reads menus, the extension and cached buttons only
    // (cheap, every tick); search=true also looks for buttons not found yet.
    func controls(for call: Call, search: Bool) -> [Action: Control] {
        if call.app != app { cache = [:]; app = call.app }
        if call.route == "extension" {
            guard let w = finder.web?.current() else { return [:] }
            return [
                .camera: Control(action: .camera, on: w.video, element: nil, pid: 0, window: nil, shortcut: nil, route: "extension"),
                .share: Control(action: .share, on: w.share, element: nil, pid: 0, window: nil, shortcut: nil, route: "extension"),
                .leave: Control(action: .leave, on: nil, element: nil, pid: 0, window: nil, shortcut: nil, route: "extension"),
            ]
        }
        guard let spec = Self.specs[call.app], call.pid != 0 else { return [:] }
        var out = menuControls(call.pid, spec)
        for (action, rules) in spec.buttons where out[action] == nil {
            if let c = cache[action], c.route != "shortcut" || !search {
                if c.route == "shortcut" { out[action] = c; continue }
                if let n = c.element.flatMap({ AX.node($0) }), let r = Rule.first(rules, n) {
                    out[action] = Control(action: action, on: r.on, element: c.element, pid: c.pid, window: c.window,
                                          shortcut: nil, route: "cached")
                    continue
                }
                cache[action] = nil // went stale (the toolbar was rebuilt); search again below
            }
            guard search else { continue }
            let wins = windows(call, spec)
            if let hit = find(rules, hint: spec.hints[action], in: wins, pid: call.pid) {
                let (n, w) = hit
                let c = Control(action: action, on: Rule.first(rules, n)?.on, element: n.element, pid: call.pid,
                                window: w, shortcut: nil, route: "button")
                cache[action] = c
                out[action] = c
            } else if let s = spec.shortcuts[action] {
                let c = Control(action: action, on: nil, element: nil, pid: call.pid, window: call.window ?? wins.first,
                                shortcut: (s.0, s.1), route: "shortcut")
                cache[action] = c
                out[action] = c
            }
        }
        return out
    }

    private func menuControls(_ pid: pid_t, _ spec: Spec) -> [Action: Control] {
        guard !spec.menuRules.isEmpty, let bar = AX.value(AX.app(pid), kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [:] }
        var out: [Action: Control] = [:]
        for item in AX.elements(bar as! AXUIElement, kAXChildrenAttribute)
        where spec.menus.contains(AX.string(item, kAXTitleAttribute) ?? "") {
            for menu in AX.elements(item, kAXChildrenAttribute) {
                for mi in AX.elements(menu, kAXChildrenAttribute) {
                    let v = AX.values(mi, [kAXTitleAttribute, kAXEnabledAttribute])
                    let title = (v[0] as? String) ?? ""
                    guard (v[1] as? Bool) == true else { continue }
                    for (action, rules) in spec.menuRules where out[action] == nil {
                        if let r = rules.first(where: { $0.matches(title: title, desc: "") }) {
                            out[action] = Control(action: action, on: r.on, element: mi, pid: pid, window: nil,
                                                  shortcut: nil, route: "menu")
                        }
                    }
                }
            }
        }
        return out
    }

    private func windows(_ call: Call, _ spec: Spec) -> [AXUIElement] {
        let all = AX.windows(AX.app(call.pid))
        switch spec.windows {
        case .micWindow: return call.window.map { [$0] } ?? all
        case .all: return all
        case .titled(let parts):
            return all.filter { w in
                let t = (AX.string(w, kAXTitleAttribute) ?? "").lowercased()
                return parts.contains { t.contains($0) }
            }
        }
    }

    private func find(_ rules: [Rule], hint: String?, in wins: [AXUIElement], pid: pid_t) -> (Node, AXUIElement)? {
        finder.enableWebAX(pid)
        for w in wins {
            if let n = AX.findButton(w, budget: budget, hint: hint, { Rule.first(rules, $0) != nil }) { return (n, w) }
        }
        return nil
    }

    // MARK: acting

    func press(_ c: Control, call: Call) -> Bool {
        if c.route == "extension" { return finder.web?.command(Self.extensionCommands[c.action]!) ?? false }
        if let e = c.element {
            guard AX.press(e) else { cache[c.action] = nil; return false }
            if c.action == .leave && call.app == "Zoom" { confirmZoomLeave(c.pid) }
            return true
        }
        guard let s = c.shortcut else { return false }
        finder.sendShortcut(pid: c.pid, window: c.window, s.key, s.flags)
        return true
    }

    // Zoom asks before leaving. "Leave Meeting" is the participant's way out and the host's too;
    // "End Meeting for All" is never pressed.
    private func confirmZoomLeave(_ pid: pid_t) {
        let rule = [Rule.exact("leave meeting")]
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            usleep(100_000)
            if let n = find(rule, hint: nil, in: AX.windows(AX.app(pid)), pid: pid)?.0 {
                Log.i("leave: Zoom asked, pressing Leave Meeting (ok=\(AX.press(n.element)))")
                return
            }
        }
    }

    // The state after a press: the tab reports back, or the app relabels its button.
    func readBack(_ c: Control, call: Call) -> Bool? {
        if c.route == "extension", let web = finder.web {
            let read: (WebCall) -> Bool? = c.action == .camera ? { $0.video } : { $0.share }
            return web.awaitValue(read, not: c.on, timeout: 0.6) ?? nil
        }
        usleep(350_000)
        return controls(for: call, search: false)[c.action]?.on
    }

    func bringToFront(_ call: Call) {
        if call.route == "extension" { _ = finder.web?.command("front"); return }
        guard call.pid != 0 else { return }
        var w = call.window
        if w == nil, let spec = Self.specs[call.app] { w = windows(call, spec).first }
        AX.focus(pid: call.pid, window: w ?? AX.windows(AX.app(call.pid)).first)
    }
}
