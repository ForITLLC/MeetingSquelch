// RemoteProtocol.swift: the wire contract between Squelch on the Mac and the iPhone remote.
// docs/remote-protocol.md explains it. Foundation and CryptoKit only, because the Mac app compiles this
// file straight into its own binary (build.sh) and the iPhone app gets it as the SquelchProtocol module.
// Everything here is public for the iPhone side; in the Mac build it is simply part of the app module.
import CryptoKit
import Foundation

public enum Remote {
    public static let proto = "forit.squelch.remote"
    public static let version = 1
    public static let serviceType = "_squelch._tcp"
    public static let defaultPort: UInt16 = 47214
    public static let pairScheme = "squelch-pair"
    public static let nonceBytes = 16
    public static let keyBytes = 32
    /// The actions a phone may ask for. The same names as the browser extension's "do" message.
    public static let actions: Set<String> = ["mic", "camera", "share", "leave", "front"]
}

public enum RemoteError: Error, Equatable {
    case badFrame
    case replay
    case badKey
}

// MARK: pairing

/// What the Mac's pairing QR code carries. The key is the phone's long-term secret for this Mac: whoever
/// holds it can press mute, so the code is only shown on the Mac's screen, for one phone, for five minutes.
public struct RemotePairing: Equatable {
    public var mac: String       // the Mac's id, also in its Bonjour TXT record as "id"
    public var name: String      // the Mac's name, shown on the phone
    public var key: Data         // 32 random bytes
    public var host: String?     // e.g. "my-mac.local", tried when Bonjour finds nothing
    public var port: UInt16

    public init(mac: String, name: String, key: Data, host: String? = nil, port: UInt16 = Remote.defaultPort) {
        self.mac = mac
        self.name = name
        self.key = key
        self.host = host
        self.port = port
    }

    /// squelch-pair://v1?m=<mac>&n=<name>&k=<base64url key>&h=<host>&p=<port>
    public var url: URL {
        var c = URLComponents()
        c.scheme = Remote.pairScheme
        c.host = "v1"
        c.queryItems = [URLQueryItem(name: "m", value: mac), URLQueryItem(name: "n", value: name),
                        URLQueryItem(name: "k", value: key.base64URL), URLQueryItem(name: "p", value: String(port))]
            + (host.map { [URLQueryItem(name: "h", value: $0)] } ?? [])
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == Remote.pairScheme, url.host == "v1",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let mac = q("m"), !mac.isEmpty, let key = q("k").flatMap(Data.init(base64URL:)),
              key.count == Remote.keyBytes else { return nil }
        self.init(mac: mac, name: q("n") ?? "Mac", key: key, host: q("h"),
                  port: q("p").flatMap(UInt16.init) ?? Remote.defaultPort)
    }

    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

// MARK: handshake (plain JSON text frames)

/// phone -> Mac, first frame. pair = true on the first connection after scanning the code.
public struct RemoteHello: Codable, Equatable {
    public var t = "hello"
    public var proto = Remote.proto
    public var v = Remote.version
    public var device: String    // the phone's id for this Mac, chosen by the phone at pairing
    public var nonce: String     // base64, 16 random bytes
    public var pair: Bool?

    public init(device: String, nonce: Data, pair: Bool = false) {
        self.device = device
        self.nonce = nonce.base64EncodedString()
        self.pair = pair ? true : nil
    }
}

/// Mac -> phone, the answer to hello. After it every frame is sealed and binary.
public struct RemoteChallenge: Codable, Equatable {
    public var t = "challenge"
    public var mac: String
    public var nonce: String

    public init(mac: String, nonce: Data) {
        self.mac = mac
        self.nonce = nonce.base64EncodedString()
    }
}

/// Mac -> phone instead of a challenge (plain), or sealed later. The Mac closes the socket after it.
public struct RemoteRefusal: Codable, Equatable {
    public var t = "error"
    public var why: String       // "not paired" | "bad hello" | "pairing closed"
    public init(why: String) { self.why = why }
}

// MARK: messages (sealed)

/// Every sealed message. Fields not used by a type are left out of the JSON.
///   phone -> Mac: hi {name}   do {id, what}   ping
///   Mac -> phone: state {app, muted, camera, share, mic}   done {id, what, ok, muted}   pong   bye {why}
/// state.app nil = no call; then muted is the Mac's mic (nil = that mic has no mute switch) and mic is its name.
public struct RemoteMessage: Codable, Equatable {
    public var t: String
    public var id: Int?
    public var what: String?
    public var name: String?
    public var app: String?
    public var muted: Bool?
    public var camera: Bool?
    public var share: Bool?
    public var mic: String?
    public var ok: Bool?
    public var why: String?

    public init(t: String, id: Int? = nil, what: String? = nil, name: String? = nil, app: String? = nil,
                muted: Bool? = nil, camera: Bool? = nil, share: Bool? = nil, mic: String? = nil,
                ok: Bool? = nil, why: String? = nil) {
        self.t = t
        self.id = id
        self.what = what
        self.name = name
        self.app = app
        self.muted = muted
        self.camera = camera
        self.share = share
        self.mic = mic
        self.ok = ok
        self.why = why
    }

    public static func hi(name: String) -> RemoteMessage { RemoteMessage(t: "hi", name: name) }
    public static func press(_ what: String, id: Int) -> RemoteMessage { RemoteMessage(t: "do", id: id, what: what) }
    public static let ping = RemoteMessage(t: "ping")
    public static let pong = RemoteMessage(t: "pong")

    public var inCall: Bool { app != nil }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return (try? e.encode(self)) ?? Data()
    }

    public static func decode(_ d: Data) -> RemoteMessage? { try? JSONDecoder().decode(RemoteMessage.self, from: d) }
}

// MARK: session crypto

/// The two directions' keys for one connection. Both nonces are fresh per connection, so a recorded
/// session can't be replayed into a new one.
public struct RemoteSessionKeys {
    public let phoneToMac: SymmetricKey
    public let macToPhone: SymmetricKey

    public init(key: Data, phoneNonce: Data, macNonce: Data, device: String, mac: String) throws {
        guard key.count == Remote.keyBytes, phoneNonce.count == Remote.nonceBytes,
              macNonce.count == Remote.nonceBytes else { throw RemoteError.badKey }
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: phoneNonce + macNonce,
                                         info: Data("\(Remote.proto) v\(Remote.version)|\(device)|\(mac)".utf8),
                                         outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        phoneToMac = SymmetricKey(data: bytes.prefix(32))
        macToPhone = SymmetricKey(data: bytes.suffix(32))
    }
}

/// Seals one direction: ChaCha20-Poly1305, nonce = 4 zero bytes + an 8-byte big-endian counter from 1.
/// The frame is the sealed box's combined form: nonce (12) + ciphertext + tag (16).
public struct RemoteSealer {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(_ key: SymmetricKey) { self.key = key }

    public mutating func seal(_ m: RemoteMessage) throws -> Data { try seal(m.encoded()) }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        counter += 1
        var n = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { n.append(contentsOf: $0) }
        return try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: n)).combined
    }
}

/// Opens the other direction and refuses any frame whose counter is not above the last one opened.
public struct RemoteOpener {
    private let key: SymmetricKey
    private var last: UInt64 = 0

    public init(_ key: SymmetricKey) { self.key = key }

    public mutating func open(_ frame: Data) throws -> RemoteMessage {
        guard let m = RemoteMessage.decode(try openData(frame)) else { throw RemoteError.badFrame }
        return m
    }

    public mutating func openData(_ frame: Data) throws -> Data {
        guard frame.count >= 28, let box = try? ChaChaPoly.SealedBox(combined: frame) else { throw RemoteError.badFrame }
        let nonce = Data(box.nonce)
        guard nonce.prefix(4) == Data(count: 4) else { throw RemoteError.badFrame }
        let counter = nonce.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter > last else { throw RemoteError.replay }
        guard let plain = try? ChaChaPoly.open(box, using: key) else { throw RemoteError.badFrame }
        last = counter
        return plain
    }
}

public extension Data {
    static func random(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
