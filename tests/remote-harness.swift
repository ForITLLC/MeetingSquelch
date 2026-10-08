// remote-harness.swift: drives the real RemoteServer (Sources/RemoteServer.swift) over the network with a fake
// iPhone, on a spare port and a temp folder, so nothing touches the running Squelch. Run on any Mac:
//   tests/remote-harness.sh        (exit 0 = every check passed)
import Foundation
import Network

final class FakePhone {
    let conn: NWConnection
    private let q = DispatchQueue(label: "fake-phone")
    var sealer: RemoteSealer?
    var opener: RemoteOpener?
    var closed = false

    init(port: UInt16) {
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        conn = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/")!), using: params)
        let ready = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        conn.start(queue: q)
        _ = ready.wait(timeout: .now() + 3)
    }

    func send(_ d: Data, text: Bool) {
        let ctx = NWConnection.ContentContext(identifier: "t",
                                              metadata: [NWProtocolWebSocket.Metadata(opcode: text ? .text : .binary)])
        let sent = DispatchSemaphore(value: 0)
        conn.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in sent.signal() })
        _ = sent.wait(timeout: .now() + 2)
    }

    // The next frame, or nil when the server closed the socket or nothing came within the timeout.
    func receive(_ timeout: Double = 3) -> (Data, Bool)? {
        let got = DispatchSemaphore(value: 0)
        var out: (Data, Bool)?
        conn.receiveMessage { data, ctx, _, err in
            let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if err == nil, meta?.opcode != .close, let d = data, !d.isEmpty { out = (d, meta?.opcode == .text) }
            else { self.closed = true }
            got.signal()
        }
        if got.wait(timeout: .now() + timeout) == .timedOut { return nil }
        return out
    }

    func hello(device: String, pair: Bool) -> [String: Any]? {
        let nonce = Data.random(Remote.nonceBytes)
        send(try! JSONEncoder().encode(RemoteHello(device: device, nonce: nonce, pair: pair)), text: true)
        guard let (d, text) = receive(), text,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var r = j
        r["phoneNonce"] = nonce
        return r
    }

    func startSession(key: Data, device: String, challenge: [String: Any]) {
        let keys = try! RemoteSessionKeys(key: key, phoneNonce: challenge["phoneNonce"] as! Data,
                                          macNonce: Data(base64Encoded: challenge["nonce"] as! String)!,
                                          device: device, mac: challenge["mac"] as! String)
        sealer = RemoteSealer(keys.phoneToMac)
        opener = RemoteOpener(keys.macToPhone)
    }

    @discardableResult
    func sealed(_ m: RemoteMessage) -> Data {
        let f = try! sealer!.seal(m)
        send(f, text: false)
        return f
    }

    func next(_ timeout: Double = 3) -> RemoteMessage? {
        guard let (d, text) = receive(timeout), !text else { return nil }
        return try? opener!.open(d)
    }

    func close() { conn.cancel() }
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  " + detail)")
}

func run() {
    let port: UInt16 = 47299
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-remote-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let server = RemoteServer(port: port, dir: dir)
    var presses: [String] = []
    server.onPress = { what, reply in
        presses.append(what)
        reply(RemoteMessage(t: "done", what: what, app: "Zoom", muted: true, ok: true))
    }
    server.start()
    Thread.sleep(forTimeInterval: 1)
    let state = RemoteMessage(t: "state", app: "Zoom", muted: false, camera: true)
    server.publish(state)

    var p = FakePhone(port: port)
    check("unknown phone is refused", p.hello(device: "nobody", pair: false)?["why"] as? String == "not paired")
    p = FakePhone(port: port)
    check("pairing hello with no code open is refused", p.hello(device: "x", pair: true)?["why"] as? String == "pairing closed")

    let pairing = server.beginPairing()
    check("pairing URL parses back", RemotePairing(url: pairing.url) == pairing, pairing.url.absoluteString.replacingOccurrences(of: pairing.key.base64URL, with: "<key>"))
    let device = UUID().uuidString
    p = FakePhone(port: port)
    guard let ch = p.hello(device: device, pair: true), ch["t"] as? String == "challenge" else {
        check("pairing hello gets a challenge", false)
        return
    }
    check("pairing hello gets a challenge", ch["mac"] as? String == pairing.mac)
    p.startSession(key: pairing.key, device: device, challenge: ch)
    p.sealed(.hi(name: "Test iPhone"))
    check("state arrives after hi", p.next() == state)
    Thread.sleep(forTimeInterval: 0.3)
    check("phone saved under its name", server.phones.map(\.name) == ["Test iPhone"])
    check("pairing closed once used", !server.pairingOpen)
    let perms = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("remote.json").path))?[.posixPermissions] as? Int
    check("remote.json is 0600", perms == 0o600, String(format: "%o", perms ?? 0))

    let press = p.sealed(.press("mic", id: 5))
    let done = p.next()
    check("press gets done with its id", done?.t == "done" && done?.id == 5 && done?.ok == true && done?.muted == true,
          "\(String(describing: done))")
    p.sealed(.ping)
    check("ping gets pong", p.next() == .pong)
    p.sealed(.press("format-disk", id: 6))
    check("unknown action refused", p.next()?.ok == false)
    let changed = RemoteMessage(t: "state", app: "Zoom", muted: true, camera: true)
    server.publish(changed)
    check("state change is pushed", p.next() == changed)
    server.publish(changed)
    check("same state is not pushed twice", p.next(0.5) == nil && !p.closed)
    p.send(press, text: false)
    _ = p.next(1)
    check("replayed frame closes the connection", p.closed)
    check("replay pressed nothing", presses == ["mic"], "\(presses)")

    p = FakePhone(port: port)
    guard let ch2 = p.hello(device: device, pair: false), ch2["t"] as? String == "challenge" else {
        check("paired phone reconnects", false)
        return
    }
    p.startSession(key: pairing.key, device: device, challenge: ch2)
    p.sealed(.hi(name: "Test iPhone"))
    check("paired phone reconnects and gets state", p.next() == changed)

    let thief = FakePhone(port: port)
    if let ch3 = thief.hello(device: device, pair: false) {
        thief.startSession(key: RemotePairing.newKey(), device: device, challenge: ch3)
        thief.sealed(.press("mic", id: 1))
        _ = thief.next(1)
        check("wrong key is dropped", thief.closed)
    } else {
        check("wrong key is dropped", false, "no challenge")
    }
    check("wrong key pressed nothing", presses == ["mic"], "\(presses)")

    let late = FakePhone(port: port)
    check("second phone can't reuse the pairing", late.hello(device: "other", pair: true)?["why"] as? String == "pairing closed")

    let empty = dir.appendingPathComponent("empty")
    check("a Mac that never paired counts as off", !RemoteServer.hasPairedPhone(dir: empty))
    check("a Mac with a paired phone counts as on", RemoteServer.hasPairedPhone(dir: dir))
    server.stop()
    _ = p.next(1)
    check("stop closes a connected phone", p.closed)
    Thread.sleep(forTimeInterval: 0.5)
    check("stop closes the port", FakePhone(port: port).hello(device: device, pair: false) == nil)
    server.start()
    Thread.sleep(forTimeInterval: 1)
    p = FakePhone(port: port)
    guard let ch4 = p.hello(device: device, pair: false), ch4["t"] as? String == "challenge" else {
        check("start again lets the paired phone back in", false)
        return
    }
    p.startSession(key: pairing.key, device: device, challenge: ch4)
    p.sealed(.hi(name: "Test iPhone"))
    check("start again lets the paired phone back in", p.next() == changed)

    server.remove(device: device)
    check("removing the phone says bye", p.next()?.why == "unpaired")
    _ = p.next(1)
    check("and closes it", p.closed)
    let gone = FakePhone(port: port)
    check("removed phone is refused", gone.hello(device: device, pair: false)?["why"] as? String == "not paired")

    let idle = FakePhone(port: port)
    _ = idle.receive(12)
    check("a socket that never authenticates is closed within 10 s", idle.closed)
    try? FileManager.default.removeItem(at: dir)
}

DispatchQueue.global().async {
    run()
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
