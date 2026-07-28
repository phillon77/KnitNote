import Foundation

public struct EntitlementProjection: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let appGroupIdentifier = "group.com.phillon.KnitNote"
    public static let fileName = "EntitlementProjection.json"

    public enum State: String, Codable, Equatable, Sendable {
        case trialNotStarted
        case trial
        case permanentlyUnlocked
        case legacyPaidOwner
    }

    public let schemaVersion: Int
    public let state: State
    public let expiresAt: Date?
    public let generatedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        state: State,
        expiresAt: Date?,
        generatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.expiresAt = expiresAt
        self.generatedAt = generatedAt
    }

    public init(snapshot: EntitlementSnapshot, generatedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt

        switch snapshot {
        case .trialNotStarted:
            state = .trialNotStarted
            expiresAt = nil
        case let .trial(_, trialExpiry):
            state = .trial
            expiresAt = trialExpiry
        case .permanentlyUnlocked:
            state = .permanentlyUnlocked
            expiresAt = nil
        case .legacyPaidOwner:
            state = .legacyPaidOwner
            expiresAt = nil
        }
    }

    public func canAcceptImport(now: Date) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion else {
            return false
        }

        switch state {
        case .trial:
            guard let expiresAt else { return false }
            return now < expiresAt
        case .trialNotStarted, .permanentlyUnlocked, .legacyPaidOwner:
            return expiresAt == nil
        }
    }

    public static func canAcceptImport(
        _ projection: EntitlementProjection?,
        now: Date
    ) -> Bool {
        projection?.canAcceptImport(now: now) ?? true
    }
}
