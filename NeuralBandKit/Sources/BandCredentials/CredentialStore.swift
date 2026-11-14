import BandLogging
import BandProtocol
import Foundation
import Security

/// Non-secret facts about the stored band, kept beside the key.
public struct StoredBand: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case claimedHere, imported, encryptedBackup }

    public var name: String
    /// Bluetooth identity address for Linux/air-gestures exports (iOS can't read it; user-entered or imported).
    public var address: String?
    /// The CoreBluetooth identifier on *this* iPhone (meaningless elsewhere).
    public var peripheralID: UUID?
    public var schemeGuess: Int?
    public var firmware: String?
    public var hardware: String?
    public var serial: String?
    public var origin: Origin
    public var savedAt: Date
    public var lastConnectedAt: Date?

    public init(name: String, address: String? = nil, peripheralID: UUID? = nil, schemeGuess: Int? = nil,
                firmware: String? = nil, hardware: String? = nil, serial: String? = nil, origin: Origin,
                savedAt: Date = Date(), lastConnectedAt: Date? = nil) {
        self.name = name
        self.address = address
        self.peripheralID = peripheralID
        self.schemeGuess = schemeGuess
        self.firmware = firmware
        self.hardware = hardware
        self.serial = serial
        self.origin = origin
        self.savedAt = savedAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// The air-gestures band record, when an identity address is known.
    public var airGesturesBand: AirGesturesBand? {
        guard let address, AirGesturesBand.isValidAddress(address) else { return nil }
        return AirGesturesBand(address: address.uppercased(), name: name, schemeGuess: schemeGuess)
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public let operation: String
    public var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain \(operation) failed: \(text) (\(status))"
    }
}

/// Generic-password Keychain items, device-only (never iCloud-synced or in device backups),
/// readable after first unlock so the band can reconnect in the background.
public struct Keychain: Sendable {
    public let service: String

    public init(service: String) { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(_ account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "read") }
        return item as? Data
    }

    public func write(_ account: String, _ data: Data) throws {
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update, operation: "update") }
        var attributes = base(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "add") }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }
}

/// The band ownership credentials: the confirmed owner key, a pending key (written before
/// FinishChangeOwner, because the band may commit even if its confirmation never arrives),
/// and the non-secret band record. The Meta session lives in a separate store on purpose.
public struct CredentialStore: Sendable {
    let keys: Keychain
    let records: Keychain

    public init(namespace: String = "dev.neuralplayground") {
        keys = Keychain(service: "\(namespace).owner-key")
        records = Keychain(service: "\(namespace).band-record")
    }

    public func loadOwner() throws -> OwnerIdentity? {
        try keys.read("confirmed").map { try OwnerIdentity(ownerKeyBytes: [UInt8]($0)) }
    }

    public func loadPending() throws -> OwnerIdentity? {
        try keys.read("pending").map { try OwnerIdentity(ownerKeyBytes: [UInt8]($0)) }
    }

    public var hasOwner: Bool { (try? keys.read("confirmed")) != nil }
    public var hasPending: Bool { (try? keys.read("pending")) != nil }

    /// Saves the confirmed key and drops any pending one (air-gestures `save_identity`).
    public func saveOwner(_ identity: OwnerIdentity) throws {
        try keys.write("confirmed", Data(identity.ownerKeyBytes))
        try keys.delete("pending")
        logNotice(.credentials, "Owner key saved to Keychain (fingerprint \(identity.fingerprint), band key: \(identity.verifiesBand))")
    }

    public func savePending(_ identity: OwnerIdentity) throws {
        try keys.write("pending", Data(identity.ownerKeyBytes))
        logNotice(.credentials, "Pending owner key saved before the band commits (fingerprint \(identity.fingerprint))")
    }

    public func promotePending() throws {
        guard let pending = try loadPending() else { return }
        try saveOwner(pending)
        logNotice(.credentials, "Pending owner key confirmed by the band and promoted")
    }

    public func discardPending() throws {
        try keys.delete("pending")
        logInfo(.credentials, "Pending owner key discarded")
    }

    public func loadBand() -> StoredBand? {
        guard let data = try? records.read("band") else { return nil }
        return try? JSONDecoder().decode(StoredBand.self, from: data)
    }

    public func saveBand(_ band: StoredBand) throws {
        try records.write("band", JSONEncoder().encode(band))
    }

    /// Removes the owner key, pending key and band record from this iPhone. The band itself stays claimed.
    public func deleteAll() throws {
        try keys.delete("confirmed")
        try keys.delete("pending")
        try records.delete("band")
        logWarning(.credentials, "All local band credentials deleted by user")
    }
}
