// WatchLink.swift: what the Apple Watch app and the iPhone say to each other over WatchConnectivity. The Watch
// can't reach the Mac itself: watchOS gives apps no Bonjour and no local TCP (TN3135, low-level networking on
// watchOS). So the Watch asks the phone, the phone presses through its own link to the Mac
// (RemoteClient.pressAndStateOnce) and answers with what the Mac said. The Mac and its pairing know nothing of the
// Watch; to them it is the phone pressing.
import Foundation
@_exported import SquelchProtocol

public enum WatchLink {
    /// "mic" presses mute on the Mac; "state" reads the Mac's state without pressing anything.
    public static let asks: Set<String> = ["mic", "state"]

    static let askKey = "ask"
    static let answerKey = "answer"

    /// The Watch's message to the phone.
    public static func ask(_ what: String) -> [String: Any] { [askKey: what] }

    /// What the Watch asked for, nil for anything this phone doesn't know.
    public static func ask(from message: [String: Any]) -> String? {
        guard let what = message[askKey] as? String, asks.contains(what) else { return nil }
        return what
    }
}

/// The phone's answer to one ask.
public struct WatchAnswer: Codable, Equatable {
    public var ok: Bool
    public var mac: String?       // the paired Mac's name
    public var app: String?       // the call app; nil = no call
    public var muted: Bool?       // nil = not known, or the Mac's mic has no mute switch
    public var why: String?       // when !ok: what went wrong, as the phone says it
    public var onPhone: Bool      // only the iPhone can fix it: pair it with the Mac, or pair again

    public init(ok: Bool, mac: String? = nil, app: String? = nil, muted: Bool? = nil, why: String? = nil,
                onPhone: Bool = false) {
        self.ok = ok
        self.mac = mac
        self.app = app
        self.muted = muted
        self.why = why
        self.onPhone = onPhone
    }

    /// From the Mac's state and, after a press, its done. The done's muted is newer than the state's.
    public init(mac: String?, state: RemoteMessage?, done: RemoteMessage? = nil) {
        let failed = done?.ok == false
        self.init(ok: !failed, mac: mac, app: state?.app, muted: done?.muted ?? state?.muted,
                  why: failed ? "The Mac couldn't do that: \(done?.why ?? "no reason given")." : nil)
    }

    public static func failed(_ why: String, onPhone: Bool = false) -> WatchAnswer {
        WatchAnswer(ok: false, why: why, onPhone: onPhone)
    }

    /// The phone's reply to the Watch.
    public var message: [String: Any] {
        [WatchLink.answerKey: (try? JSONEncoder().encode(self)) ?? Data()]
    }

    /// The Watch reading the phone's reply; nil when it isn't one.
    public init?(message: [String: Any]) {
        guard let d = message[WatchLink.answerKey] as? Data,
              let a = try? JSONDecoder().decode(WatchAnswer.self, from: d) else { return nil }
        self = a
    }
}
