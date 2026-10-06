// PairingStoreTests.swift: the paired-Mac list, on the in-memory vault (the Keychain needs a signed app).
import XCTest
@testable import SquelchRemote

final class PairingStoreTests: XCTestCase {
    func pairing(_ mac: String) -> RemotePairing {
        RemotePairing(mac: mac, name: "Mac \(mac)", key: RemotePairing.newKey(), host: "\(mac).local")
    }

    func testEmptyStoreHasNoCurrent() {
        XCTAssertNil(PairingStore(vault: MemoryVault()).current)
    }

    func testSaveLoadRoundTripsEveryField() throws {
        let s = PairingStore(vault: MemoryVault())
        var p = StoredPairing(pairing("a"), device: "dev-1", added: Date(timeIntervalSince1970: 1000))
        p.lastHost = "192.168.1.20"
        p.lastPort = 47214
        p.confirmed = true
        try s.save(p)
        XCTAssertEqual(s.current, p)
        XCTAssertEqual(s.pairing(mac: "a"), p)
        XCTAssertEqual(s.current?.port, Remote.defaultPort)
    }

    func testNewestIsCurrent() throws {
        let s = PairingStore(vault: MemoryVault())
        try s.save(StoredPairing(pairing("old"), added: Date(timeIntervalSince1970: 1)))
        try s.save(StoredPairing(pairing("new"), added: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(s.current?.mac, "new")
        XCTAssertEqual(s.all().map(\.mac), ["new", "old"])
    }

    func testSaveReplacesTheSameMac() throws {
        let s = PairingStore(vault: MemoryVault())
        try s.save(StoredPairing(pairing("a")))
        try s.save(StoredPairing(pairing("a")))
        XCTAssertEqual(s.all().count, 1)
    }

    func testUpdateAndForget() throws {
        let s = PairingStore(vault: MemoryVault())
        try s.save(StoredPairing(pairing("a")))
        try s.update(mac: "a") { $0.confirmed = true }
        XCTAssertEqual(s.current?.confirmed, true)
        try s.update(mac: "missing") { $0.confirmed = false }
        try s.forget(mac: "a")
        XCTAssertNil(s.current)
        try s.forget(mac: "a")   // forgetting twice is fine
    }

    func testUnreadableItemsAreSkipped() throws {
        let v = MemoryVault()
        try v.save(Data("not json".utf8), account: "junk")
        let s = PairingStore(vault: v)
        try s.save(StoredPairing(pairing("a")))
        XCTAssertEqual(s.all().map(\.mac), ["a"])
    }

    func testNewPairingIsUnconfirmedWithAFreshDevice() {
        let a = StoredPairing(pairing("a")), b = StoredPairing(pairing("a"))
        XCTAssertFalse(a.confirmed)
        XCTAssertNotEqual(a.device, b.device)
        XCTAssertEqual(a.host, "a.local")
    }

    func testErrorsHaveWordsAndTheRightRetry() {
        let all: [RemoteClientError] = [.notPaired, .notFound, .localNetworkDenied, .refused("not paired"),
                                        .refused("pairing closed"), .refused("bad hello"), .refused("other"),
                                        .wrongKey, .timedOut, .disconnected, .unpaired, .notConnected]
        for e in all { XCTAssertFalse(e.message.isEmpty, "\(e)") }
        XCTAssertEqual(all.filter(\.retryable), [.notFound, .localNetworkDenied, .timedOut, .disconnected, .notConnected])
        XCTAssertEqual(all.filter(\.needsPairing), [.notPaired, .refused("not paired"), .refused("pairing closed"),
                                                    .wrongKey, .unpaired])
    }
}
