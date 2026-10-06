// HotKey.swift: one global hotkey through Carbon's RegisterEventHotKey (no Accessibility needed).
// Spec strings: "ctrl+opt+shift+cmd+m", "cmd+shift+m", "f18". The old four-modifier alias still
// parses, but the menu shows the key as words (display), never as that alias.
// Registration fails while another app holds the same chord, so it retries.
import Carbon
import Foundation

final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    let spec: String
    let display: String // "Control + Option + Shift + Command + M", for the menu, HUD and logs
    private let keyCode: UInt32
    private let mods: UInt32
    private let id: UInt32
    private var ref: EventHotKeyRef?
    private var retry: Timer?
    private(set) var registered = false

    private static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16,
        "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
    ]

    init?(spec: String, handler: @escaping () -> Void) {
        var mods = 0
        var key: Int?
        var keyName = ""
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "hyper": mods |= cmdKey | controlKey | optionKey | shiftKey
            case "cmd", "command", "⌘": mods |= cmdKey
            case "ctrl", "control", "⌃": mods |= controlKey
            case "opt", "alt", "option", "⌥": mods |= optionKey
            case "shift", "⇧": mods |= shiftKey
            default: key = Self.keys[part]; keyName = part
            }
        }
        guard let k = key else { return nil }
        self.spec = spec
        let names: [(Int, String)] = [(controlKey, "Control"), (optionKey, "Option"), (shiftKey, "Shift"), (cmdKey, "Command")]
        self.display = (names.filter { mods & $0.0 != 0 }.map { $0.1 } + [keyName == "space" ? "Space" : keyName.uppercased()]).joined(separator: " + ")
        self.keyCode = UInt32(k)
        self.mods = UInt32(mods)
        self.id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        Self.install()
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.handlers[hk.id]?()
            return noErr
        }, 1, &type, nil, nil)
    }

    // Registers now, or keeps retrying every 2 s until the chord is free.
    func register() {
        guard !registered else { return }
        let hkID = EventHotKeyID(signature: OSType(0x434D_5554), id: id) // 'CMUT'
        let st = RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        if st == noErr {
            registered = true
            retry?.invalidate(); retry = nil
            Log.i("hotkey \(display) registered")
            return
        }
        if retry == nil {
            Log.i("hotkey \(display) not available (OSStatus \(st)), retrying every 2 s")
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.register() }
        }
    }

    func unregister() {
        retry?.invalidate(); retry = nil
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil
        registered = false
    }
}
