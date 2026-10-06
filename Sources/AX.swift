// AX.swift: the Accessibility calls, kept few and batched because each one is a round trip
// into the target app. Attributes come in one AXUIElementCopyMultipleAttributeValues call.
// Inside a web view (Teams, Meet in Edge or Chrome) buttons come from the engine's own search
// (AXUIElementsForSearchPredicate, the call VoiceOver's rotor uses); a breadth-first walk with a
// node budget is the fallback when the engine does not answer it.
import AppKit
import ApplicationServices

struct Node {
    let element: AXUIElement
    let role: String
    let title: String
    let desc: String
    var label: String { title + " " + desc } // the same text call-mute.lua matched

    init(element: AXUIElement, role: String, title: AnyObject?, desc: AnyObject?) {
        self.element = element
        self.role = role
        self.title = (title as? String) ?? ""
        self.desc = (desc as? String) ?? ""
    }
}

enum SearchResult {
    case found(Node)
    case none          // the engine searched and nothing matched
    case unsupported   // no search predicate here; walk the tree instead
}

enum AX {
    static let buttonRoles: Set<String> = ["AXButton", "AXCheckBox", "AXToggleButton"]

    static func trusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func setGlobalTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    static func value(_ e: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    static func elements(_ e: AXUIElement, _ attr: String) -> [AXUIElement] {
        (value(e, attr) as? [AXUIElement]) ?? []
    }

    static func string(_ e: AXUIElement, _ attr: String) -> String? { value(e, attr) as? String }

    static func values(_ e: AXUIElement, _ attrs: [String]) -> [AnyObject?] {
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(e, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard err == .success, let arr = out as [AnyObject]?, arr.count == attrs.count else {
            return attrs.map { _ in nil }
        }
        return arr.map { v in
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    static func node(_ e: AXUIElement) -> Node? {
        let v = values(e, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
        guard let role = v[0] as? String else { return nil }
        return Node(element: e, role: role, title: v[1], desc: v[2])
    }

    static func label(_ title: AnyObject?, _ desc: AnyObject?) -> String {
        ((title as? String) ?? "") + " " + ((desc as? String) ?? "")
    }

    static func press(_ e: AXUIElement) -> Bool {
        AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    static func setBool(_ e: AXUIElement, _ attr: String, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(e, attr as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] { elements(app, kAXWindowsAttribute) }

    // Engine-side search inside one web area. text narrows the results in the target process.
    static func search(_ web: AXUIElement, key: String, text: String?, limit: Int,
                       _ test: (Node) -> Bool) -> SearchResult {
        var params: [String: Any] = [
            "AXSearchKey": key,
            "AXResultsLimit": limit,
            "AXDirection": "AXDirectionNext",
            "AXImmediateDescendantsOnly": false,
            "AXVisibleOnly": false,
        ]
        if let text = text { params["AXSearchText"] = text }
        var out: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString,
                                                             params as CFDictionary, &out)
        guard err == .success, let hits = out as? [AXUIElement] else { return .unsupported }
        for h in hits {
            if let n = node(h), test(n) { return .found(n) }
        }
        return .none
    }

    // Breadth-first walk of one window for the first button whose label passes test().
    // A web area is asked to search itself first; its subtree is only walked when it cannot.
    static func findButton(_ root: AXUIElement, budget: Int, hint: String?, _ test: (Node) -> Bool) -> Node? {
        var queue: [AXUIElement] = [root]
        var i = 0
        while i < queue.count && i < budget {
            let e = queue[i]; i += 1
            let v = values(e, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            let role = (v[0] as? String) ?? ""
            if buttonRoles.contains(role) {
                let n = Node(element: e, role: role, title: v[1], desc: v[2])
                if test(n) { return n }
            }
            if role == "AXWebArea" {
                var r = hint.map { search(e, key: "AXAnyTypeSearchKey", text: $0, limit: 60, test) } ?? .none
                if case .none = r { r = search(e, key: "AXButtonSearchKey", text: nil, limit: 600, test) }
                switch r {
                case .found(let n): return n
                case .none: continue // searched by the engine; nothing to walk
                case .unsupported: break
                }
            }
            if let kids = v[3] as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return nil
    }

    // Every mic-looking control in a window, for squelch://dump (read-only).
    static func dump(_ root: AXUIElement, budget: Int) -> [String] {
        var out: [String] = []
        var queue: [AXUIElement] = [root]
        var i = 0
        while i < queue.count && i < budget {
            let e = queue[i]; i += 1
            let v = values(e, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            let role = (v[0] as? String) ?? ""
            let l = label(v[1], v[2])
            let s = l.lowercased()
            if s.contains("mute") || s.contains("microphone") || s.range(of: "\\bmic\\b", options: .regularExpression) != nil
                || l.contains("⌘ M") || l.contains("⌘M") {
                out.append("\(role) [\(l.trimmingCharacters(in: .whitespaces))]")
            }
            if let kids = v[3] as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return out
    }

    // Brings app (and window, if given) to the front through Accessibility, which works from a
    // background agent where NSRunningApplication.activate() is refused on macOS 14+.
    static func focus(pid: pid_t, window: AXUIElement?) {
        let a = app(pid)
        _ = setBool(a, kAXFrontmostAttribute, true)
        if let w = window {
            _ = setBool(w, kAXMainAttribute, true)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
    }

    // Sends one keystroke to the frontmost app. flags replace whatever modifiers are held.
    static func keystroke(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    }
}
