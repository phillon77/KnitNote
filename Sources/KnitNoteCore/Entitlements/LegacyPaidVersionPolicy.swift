import Foundation

public struct LegacyPaidVersionPolicy: Sendable {
    public let maximumPaidVersion: String

    public init(maximumPaidVersion: String) {
        self.maximumPaidVersion = maximumPaidVersion
    }

    public func qualifies(originalAppVersion: String) -> Bool {
        guard let original = Self.components(in: originalAppVersion),
              let maximum = Self.components(in: maximumPaidVersion)
        else { return false }

        let count = max(original.count, maximum.count)
        for index in 0..<count {
            let originalComponent = index < original.count ? original[index] : 0
            let maximumComponent = index < maximum.count ? maximum[index] : 0
            if originalComponent != maximumComponent {
                return originalComponent < maximumComponent
            }
        }
        return true
    }

    private static func components(in version: String) -> [Int]? {
        guard !version.isEmpty else { return nil }
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        })
        else { return nil }
        let parsed = components.map { Int(String($0)) }
        guard parsed.allSatisfy({ $0 != nil }) else { return nil }
        return parsed.compactMap { $0 }
    }
}

public enum PurchaseQualification: Equatable, Sendable {
    case none
    case lifetime
    case legacyPaidOwner

    public var entitlementSnapshot: EntitlementSnapshot? {
        switch self {
        case .none:
            nil
        case .lifetime:
            .permanentlyUnlocked
        case .legacyPaidOwner:
            .legacyPaidOwner
        }
    }
}

public enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    case pending
    case cancelled
}
