import CryptoKit
import SquelchProtocol
import XCTest

final class RemoteProtocolTests: XCTestCase {
    let key = Data((0..<32).map { UInt8($0) })
    let pn = Data(repeating: 1, count: 16)
    let mn = Data(repeating: 2, count: 16)

    func testPairingURLRoundTrip() throws {
        let p = RemotePairing(mac: "6F1C2A", name: "Example MacBook Pro", key: RemotePairing.newKey(),
                              host: "my-mac.local", port: 47214)
        XCTAssertEqual(p.url.scheme, "squelch-pair")
        XCTAssertEqual(RemotePairing(url: p.url), p)
    }

    func testPairingURLRefusesShortKeyAndOtherSchemes() {
        XCTAssertNil(RemotePairing(url: URL(string: "squelch-pair://v1?m=a&k=AAAA")!))
        XCTAssertNil(RemotePairing(url: URL(string: "squelch://v1?m=a&k=\(key.base64URL)")!))
        XCTAssertNil(RemotePairing(url: URL(string: "squelch-pair://v2?m=a&k=\(key.base64URL)")!))
        XCTAssertEqual(RemotePairing(url: URL(string: "squelch-pair://v1?m=a&k=\(key.base64URL)")!)?.port, 47214)
    }

    func testBothSidesDeriveTheSameKeys() throws {
        let phone = try RemoteSessionKeys(key: key, phoneNonce: pn, macNonce: mn, device: "d", mac: "m")
        let mac = try RemoteSessionKeys(key: key, phoneNonce: pn, macNonce: mn, device: "d", mac: "m")
        var s = RemoteSealer(phone.phoneToMac)
        var o = RemoteOpener(mac.phoneToMac)
        XCTAssertEqual(try o.open(try s.seal(.press("mic", id: 7))), .press("mic", id: 7))
        var s2 = RemoteSealer(mac.macToPhone)
        var o2 = RemoteOpener(phone.macToPhone)
        let st = RemoteMessage(t: "state", app: "Zoom", muted: true, camera: false)
        XCTAssertEqual(try o2.open(try s2.seal(st)), st)
    }

    func testDirectionsUseDifferentKeys() throws {
        let k = try RemoteSessionKeys(key: key, phoneNonce: pn, macNonce: mn, device: "d", mac: "m")
        var s = RemoteSealer(k.phoneToMac)
        var wrong = RemoteOpener(k.macToPhone)
        XCTAssertThrowsError(try wrong.open(try s.seal(.ping))) { XCTAssertEqual($0 as? RemoteError, .badFrame) }
    }

    func testNewNoncesGiveNewKeys() throws {
        let a = try RemoteSessionKeys(key: key, phoneNonce: pn, macNonce: mn, device: "d", mac: "m")
        let b = try RemoteSessionKeys(key: key, phoneNonce: pn, macNonce: Data(repeating: 3, count: 16), device: "d", mac: "m")
        var s = RemoteSealer(a.phoneToMac)
        var o = RemoteOpener(b.phoneToMac)
        XCTAssertThrowsError(try o.open(try s.seal(.ping)))
    }

    func testReplayAndReorderAreRefused() throws {
        let k = try RemoteSessionKeys(key: key, phoneNonce: pn, macNonce: mn, device: "d", mac: "m")
        var s = RemoteSealer(k.phoneToMac)
        var o = RemoteOpener(k.phoneToMac)
        let f1 = try s.seal(.press("mic", id: 1))
        let f2 = try s.seal(.press("mic", id: 2))
        XCTAssertEqual(try o.open(f2).id, 2)
        XCTAssertThrowsError(try o.open(f1)) { XCTAssertEqual($0 as? RemoteError, .replay) }
        XCTAssertThrowsError(try o.open(f2)) { XCTAssertEqual($0 as? RemoteError, .replay) }
    }

    func testTamperedFrameIsRefusedAndDoesNotAdvance() throws {
        let k = try RemoteSessionKeys(key: key, phoneNonce: pn, macNonce: mn, device: "d", mac: "m")
        var s = RemoteSealer(k.phoneToMac)
        var o = RemoteOpener(k.phoneToMac)
        var f = try s.seal(.press("leave", id: 1))
        f[20] ^= 1
        XCTAssertThrowsError(try o.open(f)) { XCTAssertEqual($0 as? RemoteError, .badFrame) }
        XCTAssertThrowsError(try o.open(Data([1, 2, 3])))
        XCTAssertEqual(try o.open(try s.seal(.ping)), .ping)
    }

    func testWrongLengthsAreRefused() {
        XCTAssertThrowsError(try RemoteSessionKeys(key: Data(count: 16), phoneNonce: pn, macNonce: mn, device: "d", mac: "m"))
        XCTAssertThrowsError(try RemoteSessionKeys(key: key, phoneNonce: Data(count: 8), macNonce: mn, device: "d", mac: "m"))
    }

    func testHelloJSONShape() throws {
        let h = RemoteHello(device: "D1", nonce: pn, pair: true)
        let j = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        XCTAssertEqual(j["t"] as? String, "hello")
        XCTAssertEqual(j["proto"] as? String, "forit.squelch.remote")
        XCTAssertEqual(j["v"] as? Int, 1)
        XCTAssertEqual(j["pair"] as? Bool, true)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteHello(device: "D1", nonce: pn))) as! [String: Any]
        XCTAssertNil(plain["pair"])
    }

    func testMessageOmitsUnusedFields() throws {
        let j = try JSONSerialization.jsonObject(with: RemoteMessage.press("camera", id: 3).encoded()) as! [String: Any]
        XCTAssertEqual(Set(j.keys), ["t", "id", "what"])
        XCTAssertFalse(RemoteMessage(t: "state", muted: true, mic: "RØDE").inCall)
    }

    func testBase64URL() {
        let d = Data([0xfb, 0xff, 0xfe, 0x00])
        XCTAssertFalse(d.base64URL.contains("+") || d.base64URL.contains("/") || d.base64URL.contains("="))
        XCTAssertEqual(Data(base64URL: d.base64URL), d)
    }
}
