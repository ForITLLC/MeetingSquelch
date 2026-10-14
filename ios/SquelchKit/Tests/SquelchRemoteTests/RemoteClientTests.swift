// RemoteClientTests.swift: the phone's client against FakeMac on loopback. Run on a Mac: cd ios/SquelchKit && swift test
import Network
import XCTest
@testable import SquelchRemote

@MainActor
final class RemoteClientTests: XCTestCase {
    let callState = RemoteMessage(t: "state", app: "Zoom", muted: false, camera: true, share: false)
    var fakes: [FakeMac] = []
    var clients: [RemoteClient] = []

    override func tearDown() async throws {
        for c in clients { c.stop() }
        for f in fakes { f.stop() }
        clients = []
        fakes = []
        RemoteClient.live = nil
    }

    func fake(key: Data, mac: String = UUID().uuidString, state: RemoteMessage? = nil,
              advertise: Bool = false) throws -> FakeMac {
        let f = try FakeMac(mac: mac, key: key, state: state, advertise: advertise)
        XCTAssertNotEqual(f.port, 0, "fake Mac is listening")
        fakes.append(f)
        return f
    }

    func client(_ store: PairingStore = PairingStore(vault: MemoryVault()), bonjour: Bool = false) -> RemoteClient {
        let c = RemoteClient(store: store, finder: MacFinder(wait: bonjour ? 4 : 0.1, useBonjour: bonjour),
                             phoneName: "Test iPhone")
        c.connectTimeout = 2
        clients.append(c)
        return c
    }

    func code(_ f: FakeMac, key: Data, host: String? = "127.0.0.1") -> RemotePairing {
        RemotePairing(mac: f.mac, name: "Test Mac", key: key, host: host, port: f.port)
    }

    func eventually(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    // MARK: pairing and state

    func testPairsThenGetsStateAndRemembersTheAddress() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState)
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up, "status \(c.status)")
        XCTAssertEqual(f.hellos.first?.pair, true, "first hello asks to pair")
        let gotState = await eventually { c.state == self.callState }
        XCTAssertTrue(gotState, "state \(String(describing: c.state))")
        XCTAssertEqual(f.received.first, .hi(name: "Test iPhone"))
        XCTAssertEqual(c.pairing?.confirmed, true)
        XCTAssertEqual(c.pairing?.lastHost, "127.0.0.1")
        XCTAssertEqual(c.pairing?.lastPort, f.port)
        XCTAssertEqual(c.store.current?.confirmed, true, "confirmed is saved")
    }

    func testConnectsWithoutStateBecauseThePingIsAnswered() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)              // no state yet: only the pong answers
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up, "status \(c.status)")
        XCTAssertNil(c.state)
        XCTAssertEqual(f.received.map(\.t), ["hi", "ping"])
    }

    func testReconnectAfterPairingIsAPlainHello() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState)
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up)
        c.stop()
        c.start()
        let again = await eventually { c.status == .connected && f.hellos.count == 2 }
        XCTAssertTrue(again, "status \(c.status)")
        XCTAssertNil(f.hellos.last?.pair, "a paired phone does not ask to pair again")
        XCTAssertEqual(f.hellos.first?.device, f.hellos.last?.device)
    }

    func testPairingTheSameMacAgainKeepsTheDeviceID() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        let c = client()
        try c.pair(code(f, key: key))
        let device = c.pairing?.device
        let key2 = RemotePairing.newKey()
        f.key = key2
        try c.pair(code(f, key: key2))
        XCTAssertEqual(c.pairing?.device, device)
        XCTAssertEqual(c.pairing?.key, key2)
        XCTAssertEqual(c.pairing?.confirmed, false)
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up, "status \(c.status)")
    }

    func testPairingAnotherMacForgetsTheFirst() async throws {
        let store = PairingStore(vault: MemoryVault())
        let k1 = RemotePairing.newKey(), k2 = RemotePairing.newKey()
        let f1 = try fake(key: k1), f2 = try fake(key: k2)
        let c = client(store)
        try c.pair(code(f1, key: k1))
        try c.pair(code(f2, key: k2))
        XCTAssertEqual(store.all().map(\.mac), [f2.mac])
    }

    func testUsedUpCodeRetriesAsAPairedPhone() async throws {
        // The Mac saved this phone on a link that dropped before it answered: the code is used up, the key is good.
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState)
        f.refusePair = "pairing closed"
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up, "status \(c.status)")
        XCTAssertEqual(f.hellos.map(\.pair), [true, nil])
    }

    func testExpiredCodeSaysSo() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        f.refusePair = "pairing closed"
        f.refusePlain = "not paired"      // the plain retry is refused too: the Mac never saved this phone
        let c = client()
        try c.pair(code(f, key: key))
        let failed = await eventually { if case .failed = c.status { return true } else { return false } }
        XCTAssertTrue(failed)
        XCTAssertEqual(c.status, .failed(.refused("pairing closed")), "status \(c.status)")
        XCTAssertEqual(f.hellos.map(\.pair), [true, nil])
        XCTAssertTrue(RemoteClientError.refused("pairing closed").needsPairing)
    }

    func testUnknownPhoneIsRefusedAndStops() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        f.refuseAll = "not paired"
        let store = PairingStore(vault: MemoryVault())
        var p = StoredPairing(code(f, key: key))
        p.confirmed = true
        try store.save(p)
        let c = client(store)
        c.start()
        let failed = await eventually { c.status == .failed(.refused("not paired")) }
        XCTAssertTrue(failed, "status \(c.status)")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(f.hellos.count, 1, "a refusal is not retried")
    }

    func testWrongKeyIsReported() async throws {
        let f = try fake(key: RemotePairing.newKey())
        let c = client()
        try c.pair(code(f, key: RemotePairing.newKey()))
        let failed = await eventually { c.status == .failed(.wrongKey) }
        XCTAssertTrue(failed, "status \(c.status)")
        XCTAssertTrue(f.received.isEmpty, "the Mac opened nothing")
    }

    func testAnotherMacAtTheFirstAddressIsSkipped() async throws {
        let key = RemotePairing.newKey()
        let stranger = try fake(key: RemotePairing.newKey())
        let ours = try fake(key: key, state: callState)
        let store = PairingStore(vault: MemoryVault())
        var p = StoredPairing(RemotePairing(mac: ours.mac, name: "Test Mac", key: key, host: "127.0.0.1",
                                            port: stranger.port))
        p.lastHost = "127.0.0.1"
        p.lastPort = ours.port
        try store.save(p)
        let c = client(store)
        c.start()
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up, "status \(c.status)")
        XCTAssertEqual(stranger.hellos.count, 1)
        XCTAssertTrue(stranger.received.isEmpty)
        XCTAssertEqual(c.pairing?.lastPort, ours.port)
    }

    func testNothingListeningIsNotFound() async throws {
        let f = try fake(key: RemotePairing.newKey())
        let port = f.port
        f.stop()
        let store = PairingStore(vault: MemoryVault())
        try store.save(StoredPairing(RemotePairing(mac: "gone", name: "Gone", key: RemotePairing.newKey(),
                                                   host: "127.0.0.1", port: port)))
        let c = client(store)
        c.autoReconnect = false
        c.start()
        let failed = await eventually { c.status == .failed(.notFound) }
        XCTAssertTrue(failed, "status \(c.status)")
    }

    func testNotPairedWithoutAPairing() async throws {
        let c = client()
        c.start()
        XCTAssertEqual(c.status, .idle)
        do {
            _ = try await RemoteClient.pressOnce("mic", store: c.store)
            XCTFail("pressed with no pairing")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .notPaired)
        }
    }

    // MARK: pressing

    func testPressGetsItsDoneAndUpdatesTheMute() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState)
        let c = client()
        try c.pair(code(f, key: key))
        let gotState = await eventually { c.state == self.callState }
        XCTAssertTrue(gotState)
        let done = try await c.press("mic")
        XCTAssertEqual(done.t, "done")
        XCTAssertEqual(done.id, f.received.last?.id)
        XCTAssertEqual(done.ok, true)
        XCTAssertEqual(c.state?.muted, true, "done's muted is shown at once")
        XCTAssertEqual(c.state?.app, "Zoom")
        XCTAssertEqual(c.state?.camera, true, "the rest of the state is kept")
        XCTAssertTrue(c.busy.isEmpty)
        let second = try await c.press("camera")
        XCTAssertEqual(second.id, done.id.map { $0 + 1 })
    }

    func testUnknownActionComesBackNotOK() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up)
        let done = try await c.press("format-disk")
        XCTAssertEqual(done.ok, false)
        XCTAssertEqual(done.why, "unknown action")
    }

    func testPressTimesOut() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        f.answerPress = false
        let c = client()
        c.pressTimeout = 0.5
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up)
        do {
            try await c.press("mic")
            XCTFail("press answered")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .timedOut)
        }
        XCTAssertTrue(c.busy.isEmpty)
        XCTAssertEqual(c.status, .connected, "a slow press does not drop the link")
    }

    func testPressWhenNotConnectedThrows() async throws {
        let c = client()
        do {
            try await c.press("mic")
            XCTFail("pressed while closed")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .notConnected)
        }
    }

    func testPressOnceReusesTheLiveLink() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up)
        RemoteClient.live = c
        let done = try await RemoteClient.pressOnce("mic", store: c.store)
        XCTAssertEqual(done.ok, true)
        XCTAssertEqual(f.connections, 1, "no second connection")
    }

    func testPressOnceConnectsPressesAndCloses() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        let store = PairingStore(vault: MemoryVault())
        var p = StoredPairing(code(f, key: key))
        p.confirmed = true
        try store.save(p)
        let done = try await RemoteClient.pressOnce("mic", store: store, phoneName: "Test iPhone", timeout: 4)
        XCTAssertEqual(done.ok, true)
        XCTAssertEqual(f.received.map(\.t), ["hi", "ping", "do"])
        let closed = await eventually { f.open == 0 }
        XCTAssertTrue(closed, "the one-shot link is closed afterwards")
    }

    // The Watch's press: the done, and the call it went to.
    func testPressAndStateOnceGivesTheCallItPressedIn() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState)
        let store = PairingStore(vault: MemoryVault())
        var p = StoredPairing(code(f, key: key))
        p.confirmed = true
        try store.save(p)
        let (done, state) = try await RemoteClient.pressAndStateOnce("mic", store: store, phoneName: "Test iPhone",
                                                                     timeout: 4)
        XCTAssertEqual(done.ok, true)
        XCTAssertEqual(done.what, "mic")
        XCTAssertEqual(state?.app, "Zoom")
        XCTAssertEqual(f.received.filter { $0.t == "do" }.count, 1, "one press")
        let closed = await eventually { f.open == 0 }
        XCTAssertTrue(closed, "the one-shot link is closed afterwards")
    }

    func testPressAndStateOnceWithoutAPairingIsNotPaired() async throws {
        do {
            _ = try await RemoteClient.pressAndStateOnce("mic", store: PairingStore(vault: MemoryVault()))
            XCTFail("pressed with no pairing")
        } catch let e as RemoteClientError {
            XCTAssertEqual(e, .notPaired)
        }
    }

    // MARK: reading the state

    func testStateOnceReadsTheMacsStateAndCloses() async throws {
        let key = RemotePairing.newKey()
        let sharing = RemoteMessage(t: "state", app: "Teams", muted: true, camera: false, share: true,
                                    mic: "RØDE Wireless MICRO")
        let f = try fake(key: key, state: sharing)
        let store = PairingStore(vault: MemoryVault())
        var p = StoredPairing(code(f, key: key))
        p.confirmed = true
        try store.save(p)
        let st = try await RemoteClient.stateOnce(store: store, phoneName: "Test iPhone")
        XCTAssertEqual(st, sharing)
        XCTAssertEqual(st?.app, "Teams")
        XCTAssertEqual(st?.muted, true)
        XCTAssertEqual(st?.camera, false)
        XCTAssertEqual(st?.share, true)
        XCTAssertEqual(st?.mic, "RØDE Wireless MICRO")
        let closed = await eventually { f.open == 0 }
        XCTAssertTrue(closed, "the one-shot link is closed afterwards")
        XCTAssertFalse(f.received.contains(where: { $0.t == "do" }), "reading the state presses nothing")
    }

    func testStateOnceIsNilWhenTheMacHasNone() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)              // no state yet: only the pong answers
        let store = PairingStore(vault: MemoryVault())
        var p = StoredPairing(code(f, key: key))
        p.confirmed = true
        try store.save(p)
        let st = try await RemoteClient.stateOnce(store: store, phoneName: "Test iPhone")
        XCTAssertNil(st)
        XCTAssertEqual(f.received.map(\.t), ["hi", "ping"])
        let closed = await eventually { f.open == 0 }
        XCTAssertTrue(closed, "the one-shot link is closed afterwards")
    }

    // MARK: the link

    func testByeForgetsTheMac() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up)
        f.bye()
        let gone = await eventually { c.status == .failed(.unpaired) }
        XCTAssertTrue(gone, "status \(c.status)")
        XCTAssertNil(c.pairing)
        XCTAssertNil(c.store.current, "the key is deleted")
    }

    func testStateChangesArePushed() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState)
        let c = client()
        try c.pair(code(f, key: key))
        let first = await eventually { c.state == self.callState }
        XCTAssertTrue(first)
        let noCall = RemoteMessage(t: "state", muted: true, mic: "RØDE Wireless MICRO")
        f.publish(noCall)
        let pushed = await eventually { c.state == noCall }
        XCTAssertTrue(pushed)
        XCTAssertEqual(c.state?.inCall, false)
    }

    func testPingKeepsTheLinkAndASilentMacIsDropped() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState)
        let c = client()
        c.pingEvery = 0.3
        c.autoReconnect = false
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up)
        let pinged = await eventually { f.received.filter { $0.t == "ping" }.count >= 3 }
        XCTAssertTrue(pinged, "pings every pingEvery")
        XCTAssertEqual(c.status, .connected, "answered pings keep the link")
        f.answerPing = false
        let dropped = await eventually { c.status == .failed(.disconnected) }
        XCTAssertTrue(dropped, "status \(c.status)")
    }

    func testReconnectsAfterTheMacGoesAway() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState)
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up)
        f.dropAll()
        let down = await eventually { c.status == .failed(.disconnected) }
        XCTAssertTrue(down, "status \(c.status)")
        let back = await eventually(5) { c.status == .connected && f.connections == 2 }
        XCTAssertTrue(back, "status \(c.status), connections \(f.connections)")
        XCTAssertNil(f.hellos.last?.pair)
    }

    func testForgetClosesAndDeletes() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { c.status == .connected }
        XCTAssertTrue(up)
        c.forget()
        XCTAssertEqual(c.status, .idle)
        XCTAssertNil(c.store.current)
        let closed = await eventually { f.open == 0 }
        XCTAssertTrue(closed)
    }

    // MARK: the screens' sample

    func testSampleShowsTheCallAndNeitherConnectsNorStoresNorLeavesAPairingAlone() async throws {
        let key = RemotePairing.newKey()
        let f = try fake(key: key)
        let c = client()
        try c.pair(code(f, key: key))
        let up = await eventually { f.open == 1 }
        XCTAssertTrue(up)

        c.showSample(mac: "Studio Mac", state: callState)
        XCTAssertEqual(c.status, .connected)
        XCTAssertEqual(c.state, callState)
        XCTAssertEqual(c.pairing?.name, "Studio Mac")
        XCTAssertEqual(c.store.current?.name, "Test Mac", "the stored pairing is untouched")
        let closed = await eventually { f.open == 0 }
        XCTAssertTrue(closed, "the real link is closed")

        c.stop()
        c.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(c.status, .connected, "start and stop leave the sample")
        XCTAssertEqual(f.open, 0, "nothing connects")

        c.showSample(mac: nil, state: callState)
        XCTAssertNil(c.pairing, "unpaired: the pairing screen")
        XCTAssertNil(c.state)
        XCTAssertEqual(c.status, .idle)
        XCTAssertNotNil(c.store.current)
    }

    // MARK: Bonjour

    func testBonjourFindsTheMacByItsID() async throws {
        if ProcessInfo.processInfo.environment["SQUELCH_SKIP_BONJOUR"] != nil { throw XCTSkip("SQUELCH_SKIP_BONJOUR") }
        let key = RemotePairing.newKey()
        let f = try fake(key: key, state: callState, advertise: true)
        let c = client(bonjour: true)
        try c.pair(code(f, key: key, host: nil))      // no host in the code: only Bonjour can find it
        let up = await eventually(8) { c.status == .connected }
        XCTAssertTrue(up, "status \(c.status)")
        XCTAssertNotNil(c.pairing?.lastHost, "the resolved address is remembered")
    }
}
