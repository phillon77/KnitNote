import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct EntitlementProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func expiredProjectionRejectsShareImport() {
        let projection = EntitlementProjection(
            schemaVersion: 1,
            state: .trial,
            expiresAt: now,
            generatedAt: now.addingTimeInterval(-60)
        )

        #expect(!projection.canAcceptImport(now: now))
    }

    @Test func absentProjectionAllowsStagingForFirstTrialStart() {
        #expect(EntitlementProjection.canAcceptImport(nil, now: now))
    }

    @Test func firstUseAndUnlockedStatesAcceptShareImport() {
        for state in [
            EntitlementProjection.State.trialNotStarted,
            .permanentlyUnlocked,
            .legacyPaidOwner,
        ] {
            let projection = EntitlementProjection(
                schemaVersion: 1,
                state: state,
                expiresAt: nil,
                generatedAt: now
            )

            #expect(projection.canAcceptImport(now: now))
        }
    }

    @Test func activeTrialAcceptsUntilButNotAtExpiry() {
        let projection = EntitlementProjection(
            schemaVersion: 1,
            state: .trial,
            expiresAt: now.addingTimeInterval(1),
            generatedAt: now
        )

        #expect(projection.canAcceptImport(now: now))
        #expect(!projection.canAcceptImport(now: now.addingTimeInterval(1)))
    }

    @Test func unsupportedOrMalformedProjectionFailsClosed() {
        let unsupported = EntitlementProjection(
            schemaVersion: 2,
            state: .permanentlyUnlocked,
            expiresAt: nil,
            generatedAt: now
        )
        let trialWithoutExpiry = EntitlementProjection(
            schemaVersion: 1,
            state: .trial,
            expiresAt: nil,
            generatedAt: now
        )
        let nonTrialWithExpiry = EntitlementProjection(
            schemaVersion: 1,
            state: .legacyPaidOwner,
            expiresAt: now.addingTimeInterval(60),
            generatedAt: now
        )

        #expect(!unsupported.canAcceptImport(now: now))
        #expect(!trialWithoutExpiry.canAcceptImport(now: now))
        #expect(!nonTrialWithExpiry.canAcceptImport(now: now))
    }

    @Test func snapshotConversionExposesOnlyProjectionFields() throws {
        let startedAt = now.addingTimeInterval(-60)
        let projection = EntitlementProjection(
            snapshot: .trial(
                startedAt: startedAt,
                expiresAt: now.addingTimeInterval(60)
            ),
            generatedAt: now
        )

        #expect(projection == EntitlementProjection(
            schemaVersion: 1,
            state: .trial,
            expiresAt: now.addingTimeInterval(60),
            generatedAt: now
        ))

        let encoded = try JSONEncoder().encode(projection)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(object.keys) == [
            "schemaVersion",
            "state",
            "expiresAt",
            "generatedAt",
        ])
        #expect(!String(decoding: encoded, as: UTF8.self).contains("startedAt"))
    }
}
