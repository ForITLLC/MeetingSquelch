// PhoneLink.swift: the Watch's end of WatchRelay (App/WatchRelay.swift). Every ask goes to the iPhone over
// WatchConnectivity, which starts Squelch there if it isn't running, and the phone answers with what the Mac said.
import Foundation
import SquelchWatchLink
import WatchConnectivity

enum Words {
    static let unreachable = "Can't reach your iPhone. Keep it near you, with Bluetooth on."
    static let oldPhone = "Update Squelch on your iPhone."

    static func of(_ error: Error) -> String {
        switch (error as? WCError)?.code {
        case .notReachable?: return unreachable
        case .messageReplyTimedOut?: return "Your iPhone didn't answer in time. Try again."
        default: return error.localizedDescription
        }
    }
}

@MainActor
final class PhoneLink: NSObject, ObservableObject {
    /// The Mac as the phone last told it; nil until it has, or after the phone couldn't reach the Mac.
    @Published private(set) var answer: WatchAnswer?
    /// What went wrong with the last ask, in words; nil when it worked.
    @Published private(set) var problem: String?
    @Published private(set) var pressing = false
    @Published private(set) var asking = false

    private var sent = 0           // asks sent; a reply to an ask older than the last one applied is dropped
    private var applied = 0
    private var waiting: String?   // asked before the session was up

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// The Mac's state, without pressing anything. Skipped while another ask is out.
    func refresh() {
        guard !asking, !pressing else { return }
        ask("state")
    }

    func toggleMute() { ask("mic") }

    private func ask(_ what: String) {
        let s = WCSession.default
        guard s.activationState == .activated else {
            if waiting != "mic" { waiting = what }
            return
        }
        guard s.isReachable else {
            problem = Words.unreachable
            return
        }
        sent += 1
        let n = sent
        if what == "mic" { pressing = true } else { asking = true }
        s.sendMessage(WatchLink.ask(what), replyHandler: { reply in
            let a = WatchAnswer(message: reply) ?? .failed(Words.oldPhone)
            Task { @MainActor in self.took(n, what, a) }
        }, errorHandler: { error in
            let a = WatchAnswer.failed(Words.of(error))
            Task { @MainActor in self.took(n, what, a) }
        })
    }

    private func took(_ n: Int, _ what: String, _ a: WatchAnswer) {
        if what == "mic" { pressing = false } else { asking = false }
        guard n > applied else { return }
        applied = n
        // An answer with no Mac in it means the phone couldn't reach the Mac: the old state would be a guess.
        answer = a.mac != nil ? a : nil
        problem = a.ok ? nil : a.why
    }

    fileprivate func sessionUp() {
        guard let w = waiting else { return }
        waiting = nil
        ask(w)
    }

    fileprivate func reachabilityChanged() {
        if WCSession.default.isReachable, problem == Words.unreachable {
            problem = nil
            refresh()
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.sessionUp() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.reachabilityChanged() }
    }
}
