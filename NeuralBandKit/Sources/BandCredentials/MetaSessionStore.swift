import BandLogging
import Foundation

/// The Meta account session from the sign-in chain. It exists only to claim a band, and is kept
/// separate from the reusable owner key: deleting it never affects reconnecting.
public struct MetaSession: Codable, Sendable {
    public static let universe = "ar"
    public let accessToken: String
    public let userID: String
    public let deviceID: String
    public let obtainedAt: Date

    public init(accessToken: String, userID: String, deviceID: String = UUID().uuidString, obtainedAt: Date = Date()) {
        self.accessToken = accessToken
        self.userID = userID
        self.deviceID = deviceID
        self.obtainedAt = obtainedAt
    }
}

public struct MetaSessionStore: Sendable {
    let keychain: Keychain

    public init(namespace: String = "dev.neuralplayground") {
        keychain = Keychain(service: "\(namespace).meta-session")
    }

    public func load() -> MetaSession? {
        guard let data = try? keychain.read("session"),
              let session = try? JSONDecoder().decode(MetaSession.self, from: data),
              !session.accessToken.isEmpty, !session.userID.isEmpty else { return nil }
        return session
    }

    public func save(_ session: MetaSession) {
        do {
            try keychain.write("session", JSONEncoder().encode(session))
            logInfo(.meta, "Meta session saved to Keychain (user id \(BandLog.mask(session.userID)))")
        } catch {
            logWarning(.meta, "Couldn't save the Meta session: \(BandLog.describe(error)); it stays in memory")
        }
    }

    public func delete() {
        try? keychain.delete("session")
        logInfo(.meta, "Meta session deleted")
    }
}
