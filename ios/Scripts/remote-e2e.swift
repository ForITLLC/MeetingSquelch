// remote-e2e.swift: the iPhone's RemoteClient (ios/SquelchKit) against the Mac's real RemoteServer
// (Sources/RemoteServer.swift), both in this one process, on a spare port and a temp folder. Nothing touches a
// running Squelch. Run on any Mac: ios/Scripts/remote-e2e.sh (exit 0 = every check passed).
import Foundation

var failures = 0
@MainActor
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    let d = detail()
    print("\(ok ? "PASS" : "FAIL") \(name)\(d.isEmpty ? "" : "  " + d)")
}

@MainActor
func eventually(_ timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return cond()
}

@MainActor
func client(_ store: PairingStore, bonjour: Bool = false) -> RemoteClient {
    let c = RemoteClient(store: store, finder: MacFinder(wait: bonjour ? 4 : 0.1, useBonjour: bonjour),
                         phoneName: "E2E iPhone")
    c.connectTimeout = 3
    return c
}

@MainActor
func run() async {
    let port: UInt16 = 47298
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-e2e-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = RemoteServer(port: port, dir: dir)
    var presses: [String] = []
    server.onPress = { what, reply in
        presses.append(what)
        reply(RemoteMessage(t: "done", what: what, app: "Zoom", muted: true, ok: true))
    }
    server.start()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let state = RemoteMessage(t: "state", app: "Zoom", muted: false, camera: true, share: false)
    server.publish(state)

    // Pair from the code the Mac would show, reached at 127.0.0.1 (the code's own host is Bonjour's .local name).
    var code = server.beginPairing()
    check("the code carries this Mac's .local host", code.host?.hasSuffix(".local") == true, code.host ?? "nil")
    code.host = "127.0.0.1"
    let store = PairingStore(vault: MemoryVault())
    let c = client(store)
    try! c.pair(code)
    check("pairs with the real server", await eventually { c.status == .connected }, "\(c.status)")
    check("gets the Mac's state", await eventually { c.state == state }, "\(String(describing: c.state))")
    check("the Mac lists the phone by its name", await eventually { server.phones.map(\.name) == ["E2E iPhone"] },
          "\(server.phones.map(\.name))")
    check("the pairing window closed", !server.pairingOpen)
    check("the pairing is confirmed with its address", c.pairing?.confirmed == true && c.pairing?.lastHost == "127.0.0.1")

    do {
        let done = try await c.press("mic")
        check("a press comes back done with its id", done.t == "done" && done.ok == true && done.id == 1, "\(done)")
        check("done's mute shows at once", c.state?.muted == true && c.state?.app == "Zoom")
        check("the Mac pressed mic once", presses == ["mic"], "\(presses)")
    } catch {
        check("a press comes back done", false, "\(error)")
    }
    let changed = RemoteMessage(t: "state", muted: true, mic: "RØDE Wireless MICRO")
    server.publish(changed)
    check("a state change is pushed", await eventually { c.state == changed })

    c.stop()
    c.start()
    check("reconnects as a paired phone", await eventually { c.status == .connected }, "\(c.status)")
    check("still one phone on the Mac", server.phones.count == 1)

    let once = try? await RemoteClient.pressOnce("camera", store: PairingStore(vault: store.vault), phoneName: "E2E iPhone")
    check("pressOnce connects, presses and closes", once?.ok == true && presses == ["mic", "camera"], "\(presses)")

    if ProcessInfo.processInfo.environment["SQUELCH_SKIP_BONJOUR"] == nil {
        c.stop()
        try! store.update(mac: code.mac) {
            $0.host = nil
            $0.lastHost = nil
        }
        let b = client(store, bonjour: true)
        b.start()
        check("Bonjour finds the real server by its id", await eventually(8) { b.status == .connected }, "\(b.status)")
        b.stop()
        let last = store.current?.lastHost ?? "nil"
        c.start()
        check("the address Bonjour found works on its own", await eventually { c.status == .connected },
              "lastHost \(last), \(c.status)")
        if c.status != .connected {
            c.stop()
            try! store.update(mac: code.mac) { $0.host = "127.0.0.1" }
            c.start()
            _ = await eventually { c.status == .connected }
        }
    }

    let late = client(PairingStore(vault: MemoryVault()))
    try! late.pair(RemotePairing(mac: code.mac, name: code.name, key: RemotePairing.newKey(), host: "127.0.0.1", port: port))
    check("a code used up or expired is reported", await eventually { late.status == .failed(.refused("pairing closed")) },
          "\(late.status)")
    late.stop()

    var stale = server.beginPairing()
    _ = server.beginPairing()               // The user opened the window again: the first code's key is replaced
    stale.host = "127.0.0.1"
    let wrong = client(PairingStore(vault: MemoryVault()))
    try! wrong.pair(stale)
    check("a replaced code is a wrong key", await eventually { wrong.status == .failed(.wrongKey) }, "\(wrong.status)")
    wrong.stop()
    server.endPairing()
    check("a wrong key pressed nothing", presses == ["mic", "camera"], "\(presses)")

    guard let device = c.pairing?.device else { return check("still paired", false) }
    server.remove(device: device)
    check("removed on the Mac: the phone forgets it", await eventually { c.status == .failed(.unpaired) && store.current == nil },
          "\(c.status)")

    let gone = PairingStore(vault: MemoryVault())
    var old = StoredPairing(code, device: device)
    old.confirmed = true
    try! gone.save(old)
    let g = client(gone)
    g.start()
    check("a removed phone is told it isn't paired", await eventually { g.status == .failed(.refused("not paired")) },
          "\(g.status)")
    g.stop()
}

Task { @MainActor in
    await run()
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
