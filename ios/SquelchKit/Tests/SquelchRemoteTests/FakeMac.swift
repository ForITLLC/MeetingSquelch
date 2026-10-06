// FakeMac.swift: the Mac's side of forit.squelch.remote v1 in-process, on a loopback WebSocket, so the phone's
// RemoteClient can be tested without Squelch. The real server is checked by Scripts/remote-e2e.sh.
import Foundation
import Network
import SquelchProtocol

final class FakeMac {
    final class Session {
        let conn: NWConnection
        var sealer: RemoteSealer?
        var opener: RemoteOpener?
        var authed = false
        init(_ c: NWConnection) { conn = c }
    }

    let mac: String
    private let q = DispatchQueue(label: "fake-mac")
    private var listener: NWListener!
    private var sessions: [ObjectIdentifier: Session] = [:]

    // Behaviour, behind the queue; the accessors below are what tests use.
    private var _key: Data
    private var _refuseAll: String?
    private var _refusePair: String?
    private var _refusePlain: String?
    private var _state: RemoteMessage?
    private var _answerPing = true
    private var _answerPress = true
    private var _hellos: [RemoteHello] = []
    private var _received: [RemoteMessage] = []
    private var _connections = 0

    private(set) var port: UInt16 = 0

    init(mac: String = UUID().uuidString, key: Data, state: RemoteMessage? = nil, advertise: Bool = false) throws {
        self.mac = mac
        _key = key
        _state = state
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        if !advertise { params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        listener = try NWListener(using: params)
        if advertise {
            listener.service = NWListener.Service(name: "Squelch test \(mac.prefix(8))", type: Remote.serviceType,
                                                  domain: nil, txtRecord: NWTXTRecord(["v": "1", "id": mac]))
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { st in
            if case .ready = st { ready.signal() }
            if case .failed = st { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: q)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { stop() }

    func stop() {
        listener?.cancel()
        q.sync { for s in sessions.values { s.conn.cancel() } }
    }

    var key: Data { get { q.sync { _key } } set { q.sync { _key = newValue } } }
    var refuseAll: String? { get { q.sync { _refuseAll } } set { q.sync { _refuseAll = newValue } } }
    var refusePair: String? { get { q.sync { _refusePair } } set { q.sync { _refusePair = newValue } } }
    var refusePlain: String? { get { q.sync { _refusePlain } } set { q.sync { _refusePlain = newValue } } }
    var answerPing: Bool { get { q.sync { _answerPing } } set { q.sync { _answerPing = newValue } } }
    var answerPress: Bool { get { q.sync { _answerPress } } set { q.sync { _answerPress = newValue } } }
    var hellos: [RemoteHello] { q.sync { _hellos } }
    var received: [RemoteMessage] { q.sync { _received } }
    var connections: Int { q.sync { _connections } }
    var open: Int { q.sync { sessions.count } }

    /// Pushes a state to every authenticated phone, as Squelch does when the call changes.
    func publish(_ m: RemoteMessage) {
        q.sync {
            _state = m
            for s in sessions.values where s.authed { send(m, to: s) }
        }
    }

    /// The user removed this phone on the Mac.
    func bye() {
        q.sync {
            for s in sessions.values where s.authed { send(RemoteMessage(t: "bye", why: "unpaired"), to: s, thenClose: true) }
        }
    }

    /// The sockets close without a word (the Mac slept, Squelch restarted); the listener stays up.
    func dropAll() {
        q.sync { for s in sessions.values { s.conn.cancel() } }
    }

    // MARK: server

    private func accept(_ c: NWConnection) {
        let s = Session(c)
        let id = ObjectIdentifier(c)
        sessions[id] = s
        _connections += 1
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.sessions[id] = nil
            default: break
            }
        }
        c.start(queue: q)
        receive(s)
    }

    private func receive(_ s: Session) {
        s.conn.receiveMessage { [weak self] data, ctx, _, err in
            guard let self = self else { return }
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

    private func handle(_ s: Session, _ d: Data, text: Bool) -> Bool {
        guard var o = s.opener else {
            guard text, let h = try? JSONDecoder().decode(RemoteHello.self, from: d),
                  let nonce = Data(base64Encoded: h.nonce) else { return false }
            _hellos.append(h)
            if let why = _refuseAll ?? (h.pair == true ? _refusePair : _refusePlain) {
                write(try! JSONEncoder().encode(RemoteRefusal(why: why)), text: true, to: s, thenClose: true)
                return true
            }
            let macNonce = Data.random(Remote.nonceBytes)
            let keys = try! RemoteSessionKeys(key: _key, phoneNonce: nonce, macNonce: macNonce, device: h.device, mac: mac)
            s.sealer = RemoteSealer(keys.macToPhone)
            s.opener = RemoteOpener(keys.phoneToMac)
            write(try! JSONEncoder().encode(RemoteChallenge(mac: mac, nonce: macNonce)), text: true, to: s)
            return true
        }
        guard !text, let m = try? o.open(d) else { return false }
        s.opener = o
        s.authed = true
        _received.append(m)
        switch m.t {
        case "hi":
            if let st = _state { send(st, to: s) }
        case "ping":
            if _answerPing { send(.pong, to: s) }
        case "do":
            guard _answerPress else { break }
            if let what = m.what, Remote.actions.contains(what) {
                send(RemoteMessage(t: "done", id: m.id, what: what, app: "Zoom", muted: true, ok: true), to: s)
            } else {
                send(RemoteMessage(t: "done", id: m.id, what: m.what, ok: false, why: "unknown action"), to: s)
            }
        default:
            break
        }
        return true
    }

    private func send(_ m: RemoteMessage, to s: Session, thenClose: Bool = false) {
        guard var sealer = s.sealer, let d = try? sealer.seal(m) else { return }
        s.sealer = sealer
        write(d, text: false, to: s, thenClose: thenClose)
    }

    private func write(_ d: Data, text: Bool, to s: Session, thenClose: Bool = false) {
        let ctx = NWConnection.ContentContext(identifier: "fake",
                                              metadata: [NWProtocolWebSocket.Metadata(opcode: text ? .text : .binary)])
        s.conn.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in
            if thenClose { s.conn.cancel() }
        })
    }
}
