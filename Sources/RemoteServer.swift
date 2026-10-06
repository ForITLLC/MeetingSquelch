// RemoteServer.swift: the iPhone remote's way in (docs/remote-protocol.md). A WebSocket server on port 47214
// (defaults key remotePort), advertised over Bonjour as _squelch._tcp, that only paired phones can use: every
// frame after the handshake is sealed with that phone's key (RemoteProtocol.swift, the file ios/ compiles too).
// Paired phones and the Mac's id live in ~/Library/Application Support/Squelch/remote.json (mode 0600).
import AppKit
import Network
import SystemConfiguration

final class RemoteServer {
    struct Phone: Codable {
        var device: String
        var name: String
        var key: String   // base64, 32 bytes
        var paired: String
        var seen: String?
    }

    struct Store: Codable {
        var mac: String
        var phones: [Phone]
    }

    // A pairing code shown on screen: good for one phone, for five minutes.
    struct Pending {
        let key: Data
        let until: Date
    }

    final class Session {
        let conn: NWConnection
        var device = ""
        var pairing = false
        var key = Data()
        var sealer: RemoteSealer?
        var opener: RemoteOpener?
        var authed = false
        var closing = false
        init(_ c: NWConnection) { conn = c }
    }

    let port: UInt16
    /// A press from a phone (what = mic | camera | share | leave | front). Called on the main thread;
    /// the reply is the "done" message, sent once the press has been read back.
    var onPress: ((String, @escaping (RemoteMessage) -> Void) -> Void)?
    /// The paired list changed, or a pairing finished or expired. Called on the main thread.
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "io.forit.squelch.remote")
    private let file: URL
    private var store: Store
    private var listener: NWListener?
    private var listening = false
    private var lastFailure = ""
    private var pending: Pending?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var lastState: RemoteMessage?
    private static let pairFor: TimeInterval = 300
    private static let maxSessions = 8

    init(port: UInt16, dir: URL) {
        self.port = port
        file = dir.appendingPathComponent("remote.json")
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Store.self, from: d) {
            store = s
        } else {
            store = Store(mac: UUID().uuidString, phones: [])
            save()
        }
    }

    func start() { queue.async { self.listen() } }

    var macName: String { Host.current().localizedName ?? "Mac" }

    var phones: [Phone] { queue.sync { store.phones } }

    var pairingOpen: Bool { queue.sync { pending.map { Date() < $0.until } ?? false } }

    var status: [String: Any] {
        queue.sync {
            ["port": Int(port), "listening": listening, "mac": store.mac, "paired": store.phones.map(\.name),
             "connected": sessions.values.filter(\.authed).count,
             "pairing": pending.map { Date() < $0.until } ?? false]
        }
    }

    // MARK: pairing

    /// Opens a pairing window and returns what the QR code carries.
    func beginPairing() -> RemotePairing {
        let key = RemotePairing.newKey()
        queue.sync { pending = Pending(key: key, until: Date().addingTimeInterval(Self.pairFor)) }
        Log.i("remote: pairing open for \(Int(Self.pairFor)) s")
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
        return RemotePairing(mac: store.mac, name: macName, key: key, host: host, port: port)
    }

    func endPairing() {
        queue.sync {
            if pending != nil { Log.i("remote: pairing closed") }
            pending = nil
        }
    }

    func remove(device: String) {
        queue.async {
            guard let i = self.store.phones.firstIndex(where: { $0.device == device }) else { return }
            let name = self.store.phones.remove(at: i).name
            self.save()
            Log.i("remote: removed \(name)")
            for s in self.sessions.values where s.device == device {
                self.send(RemoteMessage(t: "bye", why: "unpaired"), to: s, thenClose: true)
            }
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    /// The Mac's current call and mic, pushed to every connected phone when it changes.
    func publish(_ m: RemoteMessage) {
        queue.async {
            guard m != self.lastState else { return }
            self.lastState = m
            for s in self.sessions.values where s.authed { self.send(m, to: s) }
        }
    }

    // MARK: listener

    private func listen() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = false
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else {
            retry("listener could not be created")
            return
        }
        l.service = NWListener.Service(name: nil, type: Remote.serviceType, domain: nil,
                                       txtRecord: NWTXTRecord(["v": String(Remote.version), "id": store.mac]))
        listener = l
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self = self, let l = l, self.listener === l else { return }
            switch st {
            case .ready:
                self.listening = true
                self.lastFailure = ""
                Log.i("remote: listening on port \(self.port) as \(Remote.serviceType), \(self.store.phones.count) paired")
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

    private func retry(_ why: String) {
        if why != lastFailure {
            Log.i("remote: port \(port) not available (\(why)); retrying every 10 s")
            lastFailure = why
        }
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.listen() }
    }

    // MARK: connections

    private func accept(_ c: NWConnection) {
        guard sessions.count < Self.maxSessions else {
            c.cancel()
            return
        }
        let s = Session(c)
        let id = ObjectIdentifier(c)
        sessions[id] = s
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        c.start(queue: queue)
        receive(s)
        // A socket that has not proved its key within 10 s is closed.
        queue.asyncAfter(deadline: .now() + 10) { [weak s] in
            if let s = s, !s.authed { s.conn.cancel() }
        }
    }

    private func receive(_ s: Session) {
        s.conn.receiveMessage { [weak self, weak s] data, ctx, _, err in
            guard let self = self, let s = s else { return }
            let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if err != nil || meta?.opcode == .close || (data == nil && meta == nil) {
                s.conn.cancel()
                return
            }
            if let d = data, !d.isEmpty, !self.handle(s, d, text: meta?.opcode == .text) {
                s.conn.cancel()
                return
            }
            self.receive(s)
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let s = sessions.removeValue(forKey: id), s.authed else { return }
        Log.i("remote: \(name(of: s)) disconnected")
    }

    private func name(of s: Session) -> String {
        store.phones.first { $0.device == s.device }?.name ?? (s.pairing ? "new phone" : "phone")
    }

    // False closes the connection.
    private func handle(_ s: Session, _ d: Data, text: Bool) -> Bool {
        guard !s.closing else { return true }
        guard s.opener != nil else { return text && hello(s, d) }
        guard !text, var opener = s.opener else { return false }
        let m: RemoteMessage
        do {
            m = try opener.open(d)
            s.opener = opener
        } catch {
            Log.i("remote: dropped a frame from \(name(of: s)) (\(error))")
            return false
        }
        if !s.authed {
            s.authed = true
            if s.pairing { finishPairing(s) }
            if let i = store.phones.firstIndex(where: { $0.device == s.device }) {
                store.phones[i].seen = ISO8601DateFormatter().string(from: Date())
                save()
            }
            Log.i("remote: \(name(of: s)) connected")
        }
        switch m.t {
        case "hi":
            if let n = m.name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty,
               let i = store.phones.firstIndex(where: { $0.device == s.device }), store.phones[i].name != n {
                store.phones[i].name = String(n.prefix(60))
                save()
                DispatchQueue.main.async { self.onChange?() }
            }
            if let st = lastState { send(st, to: s) }
        case "ping":
            send(.pong, to: s)
        case "do":
            guard let what = m.what, Remote.actions.contains(what) else {
                send(RemoteMessage(t: "done", id: m.id, what: m.what, ok: false, why: "unknown action"), to: s)
                return true
            }
            Log.i("remote: \(name(of: s)) pressed \(what)")
            let id = m.id
            DispatchQueue.main.async { [weak self, weak s] in
                guard let press = self?.onPress else { return }
                press(what) { done in
                    guard let self = self else { return }
                    var r = done
                    r.id = id
                    self.queue.async { if let s = s { self.send(r, to: s) } }
                }
            }
        default: break
        }
        return true
    }

    private func hello(_ s: Session, _ d: Data) -> Bool {
        guard let h = try? JSONDecoder().decode(RemoteHello.self, from: d), h.t == "hello", h.proto == Remote.proto,
              let nonce = Data(base64Encoded: h.nonce), nonce.count == Remote.nonceBytes,
              !h.device.isEmpty, h.device.count <= 64 else {
            refuse(s, "bad hello")
            return true
        }
        if h.pair == true {
            guard let p = pending, Date() < p.until else {
                refuse(s, "pairing closed")
                return true
            }
            s.key = p.key
            s.pairing = true
        } else {
            guard let ph = store.phones.first(where: { $0.device == h.device }),
                  let k = Data(base64Encoded: ph.key) else {
                refuse(s, "not paired")
                return true
            }
            s.key = k
        }
        s.device = h.device
        let macNonce = Data.random(Remote.nonceBytes)
        guard let keys = try? RemoteSessionKeys(key: s.key, phoneNonce: nonce, macNonce: macNonce,
                                                device: h.device, mac: store.mac) else {
            refuse(s, "bad hello")
            return true
        }
        s.sealer = RemoteSealer(keys.macToPhone)
        s.opener = RemoteOpener(keys.phoneToMac)
        sendText(RemoteChallenge(mac: store.mac, nonce: macNonce), to: s)
        return true
    }

    private func finishPairing(_ s: Session) {
        pending = nil
        let now = ISO8601DateFormatter().string(from: Date())
        store.phones.removeAll { $0.device == s.device }
        store.phones.append(Phone(device: s.device, name: "iPhone", key: s.key.base64EncodedString(), paired: now, seen: now))
        save()
        Log.i("remote: paired a new phone")
        DispatchQueue.main.async { self.onChange?() }
    }

    // The phone reads why, then the socket closes; nothing more is read from it.
    private func refuse(_ s: Session, _ why: String) {
        Log.i("remote: refused a connection (\(why))")
        guard let d = try? JSONEncoder().encode(RemoteRefusal(why: why)) else { return }
        write(d, opcode: .text, to: s, thenClose: true)
    }

    private func sendText<T: Encodable>(_ v: T, to s: Session) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        write(d, opcode: .text, to: s)
    }

    private func send(_ m: RemoteMessage, to s: Session, thenClose: Bool = false) {
        guard !s.closing, var sealer = s.sealer, let d = try? sealer.seal(m) else { return }
        s.sealer = sealer
        write(d, opcode: .binary, to: s, thenClose: thenClose)
    }

    private func write(_ d: Data, opcode: NWProtocolWebSocket.Opcode, to s: Session, thenClose: Bool = false) {
        let ctx = NWConnection.ContentContext(identifier: "squelch-remote",
                                              metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        if thenClose { s.closing = true }
        s.conn.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak s] _ in
            if thenClose { s?.conn.cancel() }
        })
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(store) else { return }
        try? d.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
