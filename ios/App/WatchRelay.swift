// WatchRelay.swift: the Apple Watch's way to the Mac. The Watch can't reach the Mac itself (SquelchWatchLink), so
// it asks this phone over WatchConnectivity. iOS starts the app in the background for the message if it isn't
// running; the press goes through RemoteClient.pressAndStateOnce, the same as Control Center's, and the reply
// carries what the Mac said. iPad has no Watch: WCSession isn't supported there and this does nothing. An Apple
// Watch pairs only with an iPhone, so on Apple Vision Pro this is the stand-in below, which does nothing.
#if os(iOS)
import SquelchRemote
import SquelchWatchLink
import UIKit
import WatchConnectivity

final class WatchRelay: NSObject, WCSessionDelegate {
    static let shared = WatchRelay()

    /// Activated at launch, so a message that started the app in the background is delivered.
    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    // Switched to another Watch: take the new one's messages.
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let what = WatchLink.ask(from: message) else {
            replyHandler(WatchAnswer.failed("Update Squelch on your iPhone.").message)
            return
        }
        Task { @MainActor in
            // A background launch gets only seconds; this asks for enough to find the Mac and press.
            let bg = UIApplication.shared.beginBackgroundTask(withName: "Squelch Watch \(what)")
            let answer = await Self.answer(what)
            replyHandler(answer.message)
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
    }

    @MainActor
    static func answer(_ what: String) async -> WatchAnswer {
        let name = UIDevice.current.name
        let mac = PairingStore.shared.current?.name
        do {
            if what == "state" {
                return WatchAnswer(mac: mac, state: try await RemoteClient.stateOnce(phoneName: name))
            }
            let (done, state) = try await RemoteClient.pressAndStateOnce(what, phoneName: name)
            return WatchAnswer(mac: mac, state: state, done: done)
        } catch let e as RemoteClientError {
            return .failed(e.message, onPhone: e.needsPairing)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
#else
final class WatchRelay {
    static let shared = WatchRelay()
    func start() {}
}
#endif
