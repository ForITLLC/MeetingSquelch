// WebBridge.swift: the link to the Squelch browser extension (extension/ in this folder), so a
// Meet, Teams, Zoom or Webex call in any browser tab mutes from the shortcut and the menu bar.
// Protocol "forit.call" v1 over ws://127.0.0.1:47213 (defaults key extensionPort), JSON text frames:
//   from the extension: {t:"hello",proto,v,ext}  {t:"call",id,site,mic,camera,share}  {t:"end",id}  {t:"ping"}
//   to the extension:   {t:"do",id,what}  what = mic | camera | share | leave | front
// id is the tab and frame ("<tab>:<frame>"); mic true = muted, camera true = on, share true =
// presenting, null = the page does not show it. A tab in a call reports every 5 s and on every change.
// Only browser-extension origins get the handshake, so a web page cannot open the socket, and only
// ForIT's extension (its ID comes from ForIT's signing key) unless `defaults write io.forit.squelch
// extensionIDs -array <id>...` names others; an empty array lets any extension in (development).
import Foundation
import Network

struct WebCall {
    let id: String
    let site: String    // meet | teams | zoom | webex
    let muted: Bool?
    let video: Bool?    // camera on
    let share: Bool?    // presenting
    let at: Date

    var same: [Bool?] { [muted, video, share] }

    var app: String {
        switch site {
        case "meet": return "Meet"
        case "teams": return "Teams web"
        case "zoom": return "Zoom web"
        case "webex": return "Webex web"
        default: return site.capitalized
        }
    }
}

final class WebBridge {
    let port: UInt16
    var onChange: (() -> Void)?
    private let queue = DispatchQueue(label: "io.forit.squelch.web")
    private var listener: NWListener?
    private var listening = false
    private var lastFailure = ""
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private var identified = Set<ObjectIdentifier>() // sockets that said hello; only these get presses
    private var calls: [ObjectIdentifier: [String: WebCall]] = [:] // per connection, per tab
    private static let freshFor: TimeInterval = 12
    static let forITExtensionID = "hnaihkcljcmkkkoblpgffnkdneaneama"
    private static let allowedIDs = Set(UserDefaults.standard.stringArray(forKey: "extensionIDs") ?? [forITExtensionID])

    init(port: UInt16) { self.port = port }

    func start() { queue.async { self.listen() } }

    // The freshest in-call report from any tab. Never call from the bridge's own queue.
    func current() -> WebCall? {
        queue.sync { freshest()?.1 }
    }

    private func freshest() -> (ObjectIdentifier, WebCall)? {
        calls.flatMap { conn, tabs in tabs.values.map { (conn, $0) } }
            .filter { Date().timeIntervalSince($0.1.at) < Self.freshFor }
            .max { $0.1.at < $1.1.at }
    }

    // Sends one press (mic, camera, share, leave, front) to the tab with the freshest call.
    // False if no tab is in a call.
    func command(_ what: String) -> Bool {
        queue.sync {
            guard let (conn, call) = freshest(), identified.contains(conn) else { return false }
            send(["t": "do", "id": call.id, "what": what], to: conn)
            return true
        }
    }

    func toggleMute() -> Bool { command("mic") }

    // Waits up to timeout for the tab to report a value other than before (the tab reports back).
    func awaitValue<T: Equatable>(_ read: (WebCall) -> T, not before: T, timeout: TimeInterval) -> T? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let c = current(), read(c) != before { return read(c) }
            usleep(20_000)
        }
        return nil
    }

    func awaitMuted(not before: Bool, timeout: TimeInterval) -> Bool? {
        awaitValue({ $0.muted }, not: before, timeout: timeout) ?? nil
    }

    var status: [String: Any] {
        queue.sync {
            ["port": Int(port), "listening": listening, "connections": identified.count,
             "pinned": Self.allowedIDs.sorted(),
             "calls": calls.values.flatMap { $0.values }.map { "\($0.app) \($0.muted.map { $0 ? "muted" : "live" } ?? "mic unknown")" }]
        }
    }

    // MARK: listener

    private func listen() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // Browsers let any web page open a socket to localhost; only extensions may talk to this one.
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let ok = Self.originAllowed(origin)
            if !ok { Log.i("web: refused a socket from origin '\(origin)'") }
            return NWProtocolWebSocket.Response(status: ok ? .accept : .reject, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else {
            retry("listener could not be created")
            return
        }
        listener = l
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self = self, let l = l, self.listener === l else { return }
            switch st {
            case .ready:
                self.listening = true
                self.lastFailure = ""
                Log.i("web: listening on 127.0.0.1:\(self.port) for the browser extension")
            case .failed(let e), .waiting(let e):
                self.listener = nil
                self.listening = false
                l.cancel()
                self.retry("\(e)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
    }

    static func originAllowed(_ origin: String) -> Bool {
        let schemes = ["chrome-extension://", "moz-extension://", "safari-web-extension://"]
        guard let scheme = schemes.first(where: { origin.hasPrefix($0) }) else { return false }
        if allowedIDs.isEmpty { return true }
        let id = origin.dropFirst(scheme.count).split(separator: "/").first.map(String.init) ?? ""
        return allowedIDs.contains(id)
    }

    private func retry(_ why: String) {
        if why != lastFailure {
            Log.i("web: port \(port) not available (\(why)); retrying every 10 s")
            lastFailure = why
        }
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.listen() }
    }

    // MARK: connections

    // A refused handshake still leaves a ready socket until the page hangs up, so a socket only
    // counts once it says hello with this protocol.
    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.conns[id] = c
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, ctx, _, err in
            guard let self = self else { return }
            let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if err != nil || meta?.opcode == .close || (data == nil && meta == nil) {
                c.cancel()
                return
            }
            if let d = data, !d.isEmpty { self.handle(c, d) }
            self.receive(c)
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        guard conns.removeValue(forKey: id) != nil else { return }
        let hadCall = !(calls.removeValue(forKey: id) ?? [:]).isEmpty
        guard identified.remove(id) != nil else { return }
        Log.i("web: browser extension disconnected (\(identified.count) open)")
        if hadCall { onChange?() }
    }

    private func handle(_ c: NWConnection, _ d: Data) {
        guard let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let t = m["t"] as? String else { return }
        let conn = ObjectIdentifier(c)
        if t == "hello" {
            guard (m["proto"] as? String) == "forit.call" else {
                Log.i("web: a socket said hello with another protocol; closing it")
                c.cancel()
                return
            }
            if identified.insert(conn).inserted {
                Log.i("web: browser extension \(m["ext"] as? String ?? "?") connected (\(identified.count) open)")
            }
            return
        }
        guard identified.contains(conn) else { return }
        switch t {
        case "call":
            guard let id = m["id"] as? String else { return }
            let before = calls[conn]?[id]
            let now = WebCall(id: id, site: m["site"] as? String ?? "web", muted: m["mic"] as? Bool,
                              video: m["camera"] as? Bool, share: m["share"] as? Bool, at: Date())
            calls[conn, default: [:]][id] = now
            if before?.same != now.same {
                let mic = now.muted.map { $0 ? "muted" : "live" } ?? "mic unknown"
                let cam = now.video.map { $0 ? ", camera on" : ", camera off" } ?? ""
                let shr = now.share == true ? ", presenting" : ""
                Log.i("web: \(now.app) \(before == nil ? "call seen" : "changed"), \(mic)\(cam)\(shr)")
                onChange?()
            }
        case "end":
            guard let id = m["id"] as? String, let before = calls[conn]?.removeValue(forKey: id) else { return }
            Log.i("web: \(before.app) call ended")
            onChange?()
        default: break // ping
        }
    }

    private func send(_ obj: [String: Any], to conn: ObjectIdentifier) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let c = conns[conn] else { return }
        let ctx = NWConnection.ContentContext(identifier: "squelch",
                                              metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        c.send(content: d, contentContext: ctx, isComplete: true, completion: .idempotent)
    }
}
