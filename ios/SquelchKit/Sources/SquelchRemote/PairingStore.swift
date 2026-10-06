// PairingStore.swift: the paired Macs, kept in the Keychain under a group the app and the Controls extension
// share, so a press from Control Center or the Lock Screen reads the same key the app stored.
import Foundation
import Security
@_exported import SquelchProtocol

/// One paired Mac as the phone keeps it.
public struct StoredPairing: Codable, Equatable {
    public var device: String       // this phone's id for that Mac, sent in every hello
    public var mac: String          // the Mac's id, matched against its Bonjour TXT "id"
    public var name: String
    public var key: Data
    public var host: String?        // from the pairing code
    public var port: UInt16
    public var lastHost: String?    // the last address that worked
    public var lastPort: UInt16?
    public var confirmed: Bool      // the Mac has answered a frame sealed with this key; hellos stop asking to pair
    public var added: Date

    public init(_ p: RemotePairing, device: String = UUID().uuidString, added: Date = Date()) {
        self.device = device
        mac = p.mac
        name = p.name
        key = p.key
        host = p.host
        port = p.port
        confirmed = false
        self.added = added
    }
}

/// Where the encoded pairings live: the Keychain in the app, memory in tests.
public protocol PairingVault: AnyObject {
    func load() throws -> [Data]
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password items, one per Mac (account = mac id). Readable after the first unlock, so the Lock Screen
/// control works while the phone is locked; never synced to iCloud, never restored to another phone.
public final class KeychainVault: PairingVault {
    public let service: String
    public let accessGroup: String?
    private var groupMissing = false   // no keychain-access-groups entitlement (an unsigned simulator build)

    public init(service: String, accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ extra: [String: Any] = [:]) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecUseDataProtectionKeychain as String: true]
        if let g = accessGroup, !groupMissing { q[kSecAttrAccessGroup as String] = g }
        return q.merging(extra) { $1 }
    }

    // Retries once without the group when the build has no entitlement for it.
    private func run(_ op: () -> OSStatus) -> OSStatus {
        let st = op()
        guard st == errSecMissingEntitlement, accessGroup != nil, !groupMissing else { return st }
        groupMissing = true
        return op()
    }

    public func load() throws -> [Data] {
        var out: CFTypeRef?
        let st = run {
            SecItemCopyMatching(query([kSecMatchLimit as String: kSecMatchLimitAll,
                                       kSecReturnData as String: true]) as CFDictionary, &out)
        }
        if st == errSecItemNotFound { return [] }
        guard st == errSecSuccess else { throw KeychainError(status: st) }
        return out as? [Data] ?? []
    }

    public func save(_ data: Data, account: String) throws {
        let item = query([kSecAttrAccount as String: account])
        var st = run {
            SecItemUpdate(query([kSecAttrAccount as String: account]) as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
        }
        if st == errSecItemNotFound {
            st = run {
                SecItemAdd(item.merging([kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                         kSecAttrSynchronizable as String: false]) { $1 } as CFDictionary, nil)
            }
        }
        guard st == errSecSuccess else { throw KeychainError(status: st) }
    }

    public func delete(account: String) throws {
        let st = run { SecItemDelete(query([kSecAttrAccount as String: account]) as CFDictionary) }
        guard st == errSecSuccess || st == errSecItemNotFound else { throw KeychainError(status: st) }
    }
}

public final class MemoryVault: PairingVault {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func load() throws -> [Data] { lock.withLock { Array(items.values) } }
    public func save(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }
}

/// The paired Macs, newest first. v1 uses one (`current`); nothing stops a second.
public final class PairingStore {
    /// The group in both entitlements files ($(AppIdentifierPrefix)io.forit.squelch).
    public static let accessGroup = "UUSSWWML2A.io.forit.squelch"
    public static let shared = PairingStore(vault: KeychainVault(service: "io.forit.squelch.pairing",
                                                                accessGroup: accessGroup))

    public let vault: PairingVault

    public init(vault: PairingVault) { self.vault = vault }

    public func all() -> [StoredPairing] {
        let d = JSONDecoder()
        return ((try? vault.load()) ?? []).compactMap { try? d.decode(StoredPairing.self, from: $0) }
            .sorted { $0.added > $1.added }
    }

    public var current: StoredPairing? { all().first }

    public func pairing(mac: String) -> StoredPairing? { all().first { $0.mac == mac } }

    public func save(_ p: StoredPairing) throws {
        try vault.save(try JSONEncoder().encode(p), account: p.mac)
    }

    public func update(mac: String, _ change: (inout StoredPairing) -> Void) throws {
        guard var p = pairing(mac: mac) else { return }
        let before = p
        change(&p)
        if p != before { try save(p) }
    }

    public func forget(mac: String) throws { try vault.delete(account: mac) }
}
