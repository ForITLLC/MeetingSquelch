// MacFinderTests.swift: the order and form of the addresses tried (Bonjour itself is in RemoteClientTests).
import Network
import XCTest
@testable import SquelchRemote

@MainActor
final class MacFinderTests: XCTestCase {
    func url(_ e: NWEndpoint?) -> String? {
        if case .url(let u)? = e { return u.absoluteString }
        return nil
    }

    func testStoredAddressesAreWebSocketURLs() {
        XCTAssertEqual(url(MacFinder.endpoint(host: "my-mac.local", port: 47214)), "ws://my-mac.local:47214/")
        XCTAssertEqual(url(MacFinder.endpoint(host: "192.168.1.20", port: 47214)), "ws://192.168.1.20:47214/")
        XCTAssertEqual(url(MacFinder.endpoint(host: "fe80::1%en0", port: 47214)), "ws://[fe80::1%25en0]:47214/")
        XCTAssertNil(MacFinder.endpoint(host: "", port: 47214))
        XCTAssertNil(MacFinder.endpoint(host: "x.local", port: 0))
    }

    func testCodeHostFirstThenLastAddressWithoutDuplicates() async {
        var p = StoredPairing(RemotePairing(mac: "m", name: "Mac", key: RemotePairing.newKey(), host: "mac.local"))
        p.lastHost = "10.0.0.5"
        p.lastPort = 47214
        let f = MacFinder(useBonjour: false)
        let found = await f.search(p)
        XCTAssertEqual(found.endpoints.map(url), ["ws://mac.local:47214/", "ws://10.0.0.5:47214/"])
        XCTAssertFalse(found.bonjour)
        p.lastHost = "mac.local"
        let again = await f.search(p)
        XCTAssertEqual(again.endpoints.count, 1)
        p.host = nil
        p.lastHost = nil
        let none = await f.search(p)
        XCTAssertTrue(none.endpoints.isEmpty)
    }

    func testRememberedIPv4HasNoInterface() {
        let h = NWEndpoint.Host.ipv4(IPv4Address("10.47.0.10%en0")!)
        XCTAssertEqual(RemoteClient.hostString(h), "10.47.0.10")
        XCTAssertEqual(url(MacFinder.endpoint(host: RemoteClient.hostString(h), port: 47214)), "ws://10.47.0.10:47214/")
    }
}
