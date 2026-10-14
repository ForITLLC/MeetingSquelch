import SquelchWatchLink
import XCTest

final class WatchLinkTests: XCTestCase {
    func testAsksRoundTripAndUnknownOnesAreRefused() {
        XCTAssertEqual(WatchLink.ask(from: WatchLink.ask("mic")), "mic")
        XCTAssertEqual(WatchLink.ask(from: WatchLink.ask("state")), "state")
        // The Watch presses mute and reads state; leaving the call stays on the phone.
        XCTAssertNil(WatchLink.ask(from: WatchLink.ask("leave")))
        XCTAssertNil(WatchLink.ask(from: ["ask": 1]))
        XCTAssertNil(WatchLink.ask(from: [:]))
    }

    func testAnswerRoundTripsThroughTheMessage() {
        let a = WatchAnswer(ok: true, mac: "Example MacBook Pro", app: "Teams", muted: true)
        XCTAssertEqual(WatchAnswer(message: a.message), a)
        let f = WatchAnswer.failed("Can't find the Mac.", onPhone: false)
        XCTAssertEqual(WatchAnswer(message: f.message), f)
        XCTAssertNil(WatchAnswer(message: ["answer": Data("{}".utf8)]))
        XCTAssertNil(WatchAnswer(message: ["ask": "mic"]))
    }

    func testStateOnly() {
        let a = WatchAnswer(mac: "Mac", state: RemoteMessage(t: "state", app: "Zoom", muted: false))
        XCTAssertEqual(a, WatchAnswer(ok: true, mac: "Mac", app: "Zoom", muted: false))
        let none = WatchAnswer(mac: "Mac", state: nil)
        XCTAssertEqual(none, WatchAnswer(ok: true, mac: "Mac"))
    }

    func testThePressesMutedWinsOverTheStateBeforeIt() {
        let before = RemoteMessage(t: "state", app: "Teams", muted: false)
        let done = RemoteMessage(t: "done", id: 1, what: "mic", muted: true, ok: true)
        XCTAssertEqual(WatchAnswer(mac: "Mac", state: before, done: done),
                       WatchAnswer(ok: true, mac: "Mac", app: "Teams", muted: true))
    }

    func testAFailedPressSaysWhyAndKeepsTheState() {
        let before = RemoteMessage(t: "state", app: "Teams", muted: false)
        let done = RemoteMessage(t: "done", id: 1, what: "mic", ok: false, why: "no mute button")
        let a = WatchAnswer(mac: "Mac", state: before, done: done)
        XCTAssertFalse(a.ok)
        XCTAssertEqual(a.why, "The Mac couldn't do that: no mute button.")
        XCTAssertEqual(a.app, "Teams")
        XCTAssertEqual(a.muted, false)
        XCTAssertFalse(a.onPhone)
    }
}
