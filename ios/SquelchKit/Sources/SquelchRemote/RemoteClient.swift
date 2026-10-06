// RemoteClient.swift: the phone's end of forit.squelch.remote v1 (docs/remote-protocol.md). Finds the paired Mac,
// does the hello / challenge handshake, seals every frame after it, keeps the link alive with a ping every 20 s,
// and turns a tap into a "do" and its "done". Everything runs on the main queue.
import Foundation
import Network

public enum RemoteClientError: Error, Equatable {
    case notPaired
    case notFound
    case localNetworkDenied
    case refused(String)     // the Mac's "error" frame: "not paired" | "pairing closed" | "bad hello"
    case wrongKey
    case timedOut
    case disconnected
    case unpaired            // the Mac sent bye: the user removed this iPhone there
    case notConnected

    /// What the phone shows, in plain English.
    public var message: String {
        switch self {
        case .notPaired:
            return "This iPhone isn't paired with a Mac yet. On the Mac, choose Pair iPhone in the Squelch menu and scan the code."
        case .notFound:
            return "Can't find the Mac. Check that it's awake, Squelch is running, and both are on the same Wi-Fi."
        case .localNetworkDenied:
            return "Squelch needs Local Network access to reach the Mac. Turn it on in Settings > Apps > Squelch."
        case .refused(let why):
            switch why {
            case "not paired": return "The Mac doesn't know this iPhone any more. Forget this Mac, then pair again."
            case "pairing closed": return "That pairing code has expired. On the Mac, choose Pair iPhone again and scan the new code."
            case "bad hello": return "The Mac didn't understand this iPhone. Update Squelch on both."
            default: return "The Mac refused the connection (\(why))."
            }
        case .wrongKey:
            return "The Mac didn't accept this iPhone's key. Pair again with a new code from the Mac."
        case .timedOut:
            return "The Mac didn't answer in time."
        case .disconnected:
            return "Lost the connection to the Mac."
        case .unpaired:
            return "The Mac removed this iPhone. Pair again to use it."
        case .notConnected:
            return "Not connected to the Mac."
        }
    }

    /// Worth trying again without the user doing anything: the Mac may wake, the Wi-Fi may come back, access may be granted.
    public var retryable: Bool {
        switch self {
        case .notFound, .localNetworkDenied, .timedOut, .disconnected, .notConnected: return true
        case .notPaired, .refused, .wrongKey, .unpaired: return false
        }
    }

    /// Fixed only by scanning a new code.
    public var needsPairing: Bool {
        switch self {
        case .notPaired, .wrongKey, .unpaired: return true
        case .refused(let why): return why == "not paired" || why == "pairing closed"
        default: return false
        }
    }
}

extension RemoteClientError: LocalizedError {
    public var errorDescription: String? { message }
}

@MainActor
public final class RemoteClient: ObservableObject {
    public enum Status: Equatable {
        case idle
        case searching
        case connecting
        case connected
        case failed(RemoteClientError)
    }

    /// The app's own client while it is in the foreground, so an App Intent run in the app's process reuses
    /// its open connection instead of making another.
    public static weak var live: RemoteClient?

    @Published public private(set) var status: Status = .idle
    /// The Mac's last "state": the call app (nil = no call) and whether it is muted.
    @Published public private(set) var state: RemoteMessage?
    @Published public private(set) var pairing: StoredPairing?
    /// Actions sent and not yet answered, for the buttons' spinners.
    @Published public private(set) var busy: Set<String> = []

    public let store: PairingStore
    public let finder: MacFinder
    public var phoneName: String
    public var pressTimeout: TimeInterval = 5
    public var connectTimeout: TimeInterval = 4
    public var pingEvery: TimeInterval = 20
    /// Keep reconnecting, with backoff, after a drop or a failed search. Off for a one-shot press.
    public var autoReconnect = true

    private enum Phase { case closed, searching, opening, hello, proving, up }

    private struct Waiting {
        let what: String
        let k: CheckedContinuation<RemoteMessage, Error>
    }

    private var phase = Phase.closed
    private var gen = 0                       // bumped per attempt; callbacks from an older one are ignored
    private var conn: NWConnection?
    private var endpoints: [NWEndpoint] = []
    private var index = 0
    private var denied = false
    private var sealer: RemoteSealer?
    private var opener: RemoteOpener?
    private var phoneNonce = Data()
    private var plainHello = false            // a pairing hello came back "pairing closed": try as already paired
    private var started = false
    private var nextID = 0
    private var waiting: [Int: Waiting] = [:]
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var lastHeard = Date()
    private var backoff: TimeInterval = 1
    private var retry: DispatchWorkItem?

    public init(store: PairingStore = .shared, finder: MacFinder = MacFinder(), phoneName: String = "iPhone") {
        self.store = store
        self.finder = finder
        self.phoneName = phoneName
        pairing = store.current
    }

    public var isConnected: Bool { phase == .up }

    // MARK: lifecycle

    /// Connect to the paired Mac and stay connected (the app came to the foreground).
    public func start() {
        started = true
        pairing = store.current
        guard pairing != nil else {
            status = .idle
            return
        }
        if phase == .closed { connect() }
    }

    /// Close the link and stop reconnecting (the app went to the background).
    public func stop() {
        started = false
        cancelRetry()
        close(.disconnected)
        status = .idle
    }

    /// Store the pairing from a scanned code and connect with it. v1 remotes one Mac, so any other is forgotten.
    public func pair(_ p: RemotePairing) throws {
        let old = store.all()
        // Same Mac again: keep the device id, so the Mac replaces its entry instead of listing this phone twice.
        let device = old.first { $0.mac == p.mac }?.device ?? UUID().uuidString
        try store.save(StoredPairing(p, device: device))
        for o in old where o.mac != p.mac { try? store.forget(mac: o.mac) }
        close(.disconnected)
        cancelRetry()
        state = nil
        plainHello = false
        backoff = 1
        pairing = store.current
        started = true
        connect()
    }

    /// Forget the Mac on this phone. The Mac still lists the phone until the user removes it there.
    public func forget() {
        if let p = pairing { try? store.forget(mac: p.mac) }
        cancelRetry()
        close(.disconnected)
        pairing = nil
        state = nil
        status = .idle
    }

    /// Try now instead of waiting for the next backoff (the Retry button).
    public func reconnect() {
        cancelRetry()
        backoff = 1
        close(.disconnected)
        start()
    }

    /// Resolves once the link is up, or throws the reason it can't be.
    public func waitConnected(timeout: TimeInterval) async throws {
        if phase == .up { return }
        if case .failed(let e) = status, !e.retryable || phase == .closed && !started { throw e }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connectWaiters.append(k)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self, !self.connectWaiters.isEmpty, self.phase != .up else { return }
                    self.resumeConnectWaiters(.timedOut)
                }
            }
        }
    }

    // MARK: pressing

    /// Sends one press and returns the Mac's "done" for it (ok == false carries why).
    @discardableResult
    public func press(_ what: String) async throws -> RemoteMessage {
        guard phase == .up, conn != nil else { throw RemoteClientError.notConnected }
        nextID += 1
        let id = nextID
        busy.insert(what)
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<RemoteMessage, Error>) in
            waiting[id] = Waiting(what: what, k: k)
            send(.press(what, id: id))
            DispatchQueue.main.asyncAfter(deadline: .now() + pressTimeout) { [weak self] in
                MainActor.assumeIsolated { self?.answer(id, .failure(RemoteClientError.timedOut)) }
            }
        }
    }

    /// One press from outside the app's screen (Control Center, the Lock Screen, Siri, the Action button).
    /// Reuses the app's open link when there is one, otherwise connects once, presses, and closes.
    public static func pressOnce(_ what: String, store: PairingStore = .shared, phoneName: String = "iPhone",
                                 timeout: TimeInterval = 8) async throws -> RemoteMessage {
        if let c = live, c.isConnected { return try await c.press(what) }
        guard store.current != nil else { throw RemoteClientError.notPaired }
        let c = RemoteClient(store: store, phoneName: phoneName)
        c.autoReconnect = false
        c.start()
        defer { c.stop() }
        try await c.waitConnected(timeout: timeout)
        return try await c.press(what)
    }

    private func answer(_ id: Int, _ r: Result<RemoteMessage, Error>) {
        guard let w = waiting.removeValue(forKey: id) else { return }
        if !waiting.values.contains(where: { $0.what == w.what }) { busy.remove(w.what) }
        w.k.resume(with: r)
    }

    // MARK: connecting

    private func connect() {
        guard let p = pairing else {
            fail(.notPaired)
            return
        }
        gen += 1
        let g = gen
        phase = .searching
        status = .searching
        Task { @MainActor in
            let found = await finder.search(p)
            guard g == gen, phase == .searching else { return }
            endpoints = found.endpoints
            denied = found.denied
            index = 0
            if endpoints.isEmpty {
                fail(found.denied ? .localNetworkDenied : .notFound)
            } else {
                open()
            }
        }
    }

    private static func parameters(timeout: TimeInterval) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout))
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = false
        return params
    }

    private func open() {
        guard index < endpoints.count else {
            fail(denied ? .localNetworkDenied : .notFound)
            return
        }
        conn?.cancel()
        gen += 1
        let g = gen
        let c = NWConnection(to: endpoints[index], using: Self.parameters(timeout: connectTimeout))
        conn = c
        phase = .opening
        status = .connecting
        sealer = nil
        opener = nil
        c.stateUpdateHandler = { [weak self] st in
            MainActor.assumeIsolated { self?.changed(st, g) }
        }
        c.start(queue: .main)
        // The socket, the hello and the first sealed answer all have to fit in this.
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, g == self.gen else { return }
                switch self.phase {
                case .opening, .hello: self.next()
                case .proving: self.fail(.timedOut)
                default: break
                }
            }
        }
    }

    /// This address didn't lead to the Mac: try the next one.
    private func next() {
        conn?.cancel()
        conn = nil
        index += 1
        open()
    }

    private func changed(_ st: NWConnection.State, _ g: Int) {
        guard g == gen, let c = conn else { return }
        switch st {
        case .ready:
            guard phase == .opening else { return }
            phase = .hello
            phoneNonce = Data.random(Remote.nonceBytes)
            let pairHello = !(pairing?.confirmed ?? true) && !plainHello
            let hello = RemoteHello(device: pairing?.device ?? "", nonce: phoneNonce, pair: pairHello)
            if let d = try? JSONEncoder().encode(hello) { write(d, text: true) }
            receive(c, g)
        case .waiting(let e), .failed(let e):
            if c.currentPath?.unsatisfiedReason == .localNetworkDenied || MacFinder.isDenied(e) { denied = true }
            dropped(g)
        case .cancelled:
            dropped(g)
        default:
            break
        }
    }

    /// The socket closed or failed, by either side.
    private func dropped(_ g: Int) {
        guard g == gen else { return }
        switch phase {
        case .opening, .hello: next()
        // The Mac closes on a frame it can't open. Before the first answer that means the key is wrong; for a
        // phone the Mac has answered before it is far more likely the network.
        case .proving: fail(pairing?.confirmed == true ? .disconnected : .wrongKey)
        case .up: fail(.disconnected)
        case .closed, .searching: break
        }
    }

    private func receive(_ c: NWConnection, _ g: Int) {
        c.receiveMessage { [weak self] data, ctx, _, err in
            MainActor.assumeIsolated {
                guard let self = self, g == self.gen else { return }
                let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if err != nil || meta?.opcode == .close || (data == nil && meta == nil) {
                    self.dropped(g)
                    return
                }
                if let d = data, !d.isEmpty { self.frame(d, text: meta?.opcode == .text) }
                if g == self.gen, self.phase != .closed { self.receive(c, g) }
            }
        }
    }

    private func frame(_ d: Data, text: Bool) {
        lastHeard = Date()
        switch phase {
        case .hello:
            guard text else { return next() }
            challenge(d)
        case .proving, .up:
            guard !text, var o = opener else { return }
            do {
                let m = try o.open(d)
                opener = o
                if phase == .proving { up() }
                message(m)
            } catch {
                fail(phase == .proving && pairing?.confirmed != true ? .wrongKey : .disconnected)
            }
        default:
            break
        }
    }

    private func challenge(_ d: Data) {
        guard let p = pairing else { return fail(.notPaired) }
        if let r = try? JSONDecoder().decode(RemoteRefusal.self, from: d), r.t == "error" {
            let asked = !p.confirmed && !plainHello
            // The Mac may have saved this phone on a link that dropped before it answered; the code is then used
            // up. Ask once more as a paired phone before calling the code expired.
            if r.why == "pairing closed" && asked {
                plainHello = true
                conn?.cancel()
                conn = nil
                return open()
            }
            if r.why == "not paired" && plainHello {
                plainHello = false
                return fail(.refused("pairing closed"))
            }
            return fail(.refused(r.why))
        }
        guard let ch = try? JSONDecoder().decode(RemoteChallenge.self, from: d), ch.t == "challenge",
              let macNonce = Data(base64Encoded: ch.nonce) else { return next() }
        // Another Mac running Squelch at a remembered address: not ours, keep looking.
        guard ch.mac == p.mac else { return next() }
        guard let keys = try? RemoteSessionKeys(key: p.key, phoneNonce: phoneNonce, macNonce: macNonce,
                                                device: p.device, mac: p.mac) else { return fail(.wrongKey) }
        sealer = RemoteSealer(keys.phoneToMac)
        opener = RemoteOpener(keys.macToPhone)
        phase = .proving
        // The Mac answers hi with its state only when it has one, but always answers ping: the first sealed
        // frame back proves both sides hold the key.
        send(.hi(name: phoneName))
        send(.ping)
    }

    private func up() {
        phase = .up
        status = .connected
        backoff = 1
        plainHello = false
        if let c = conn, var p = pairing {
            p.confirmed = true
            if case .hostPort(let h, let port)? = c.currentPath?.remoteEndpoint {
                p.lastHost = Self.hostString(h)
                p.lastPort = port.rawValue
            }
            if p != pairing {
                try? store.save(p)
                pairing = p
            }
        }
        resumeConnectWaiters(nil)
        schedulePing(gen)
    }

    static func hostString(_ h: NWEndpoint.Host) -> String {
        switch h {
        case .name(let n, _): return n
        // Not "\(a)": that appends the interface ("10.47.0.10%en0"), which no URL accepts.
        case .ipv4(let a): return a.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let a): return "\(a)"
        @unknown default: return "\(h)"
        }
    }

    private func message(_ m: RemoteMessage) {
        switch m.t {
        case "state":
            state = m
        case "done":
            if m.what == "mic", m.ok != false, m.muted != nil {
                var s = state ?? RemoteMessage(t: "state")
                s.app = m.app
                s.muted = m.muted
                state = s
            }
            if let id = m.id { answer(id, .success(m)) }
        case "bye":
            if let p = pairing { try? store.forget(mac: p.mac) }
            pairing = nil
            state = nil
            fail(.unpaired)
        case "error":
            fail(.refused(m.why ?? "refused"))
        default:
            break   // pong: lastHeard is enough
        }
    }

    private func schedulePing(_ g: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pingEvery) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, g == self.gen, self.phase == .up else { return }
                // Two pings unanswered: the Mac went to sleep or off the network without closing.
                if Date().timeIntervalSince(self.lastHeard) > self.pingEvery * 2 + 1 {
                    return self.fail(.disconnected)
                }
                self.send(.ping)
                self.schedulePing(g)
            }
        }
    }

    // MARK: sending and failing

    private func send(_ m: RemoteMessage) {
        guard var s = sealer, let d = try? s.seal(m) else { return }
        sealer = s
        write(d, text: false)
    }

    private func write(_ d: Data, text: Bool) {
        let ctx = NWConnection.ContentContext(identifier: "squelch-remote",
                                              metadata: [NWProtocolWebSocket.Metadata(opcode: text ? .text : .binary)])
        conn?.send(content: d, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    /// Ends the attempt and the link, fails whatever was waiting on them.
    private func close(_ why: RemoteClientError) {
        gen += 1
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        phase = .closed
        sealer = nil
        opener = nil
        for id in Array(waiting.keys) { answer(id, .failure(why)) }
        busy = []
        resumeConnectWaiters(why)
    }

    private func fail(_ e: RemoteClientError) {
        close(e)
        status = .failed(e)
        guard started, autoReconnect, e.retryable, pairing != nil else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.started, self.phase == .closed else { return }
                self.connect()
            }
        }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: w)
        backoff = min(backoff * 2, 30)
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }

    private func resumeConnectWaiters(_ e: RemoteClientError?) {
        let ks = connectWaiters
        connectWaiters = []
        for k in ks {
            if let e = e { k.resume(throwing: e) } else { k.resume() }
        }
    }
}
