import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchEntitlementSnapshotTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func watchSnapshotRoundTripsTrialExpiry() throws {
        let entitlement = WatchEntitlementSnapshot(
            kind: .trial,
            expiresAt: Date(timeIntervalSince1970: 20_000),
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let decoded = try WatchSyncCodec.decode(
            WatchEntitlementSnapshot.self,
            from: WatchSyncCodec.encode(entitlement)
        )

        #expect(decoded == entitlement)
    }

    @Test func schemaOneSnapshotIsRejectedInsteadOfAssumingWriteAccess() {
        let data = Data(#"""
        {"schemaVersion":1,"generatedAt":10000000,"projects":[]}
        """#.utf8)

        #expect(throws: WatchSyncValidationError.unsupportedSchema) {
            _ = try WatchSyncCodec.decode(WatchSyncSnapshot.self, from: data)
        }
    }

    @Test func offlinePolicyAllowsOnlyActiveTrialAndVerifiedOwners() {
        let activeTrial = WatchEntitlementSnapshot(
            kind: .trial,
            expiresAt: now.addingTimeInterval(1),
            generatedAt: now
        )
        let expiredTrial = WatchEntitlementSnapshot(
            kind: .trial,
            expiresAt: now,
            generatedAt: now
        )
        let firstUse = WatchEntitlementSnapshot(
            kind: .trialNotStarted,
            expiresAt: nil,
            generatedAt: now
        )
        let permanent = WatchEntitlementSnapshot(
            kind: .permanentlyUnlocked,
            expiresAt: nil,
            generatedAt: now
        )
        let legacy = WatchEntitlementSnapshot(
            kind: .legacyPaidOwner,
            expiresAt: nil,
            generatedAt: now
        )

        #expect(activeTrial.canMutate(now: now))
        #expect(!expiredTrial.canMutate(now: now))
        #expect(!firstUse.canMutate(now: now))
        #expect(permanent.canMutate(now: now))
        #expect(legacy.canMutate(now: now))
    }

    @Test func malformedEntitlementFailsClosed() {
        let trialWithoutExpiry = WatchEntitlementSnapshot(
            kind: .trial,
            expiresAt: nil,
            generatedAt: now
        )
        let ownerWithExpiry = WatchEntitlementSnapshot(
            kind: .legacyPaidOwner,
            expiresAt: now.addingTimeInterval(100),
            generatedAt: now
        )

        #expect(!trialWithoutExpiry.canMutate(now: now))
        #expect(!ownerWithExpiry.canMutate(now: now))
    }

    @Test func activeSnapshotRemainsWritableOfflineUntilIPhoneSendsNewerState() {
        let expiry = now.addingTimeInterval(60)
        let lastActiveSnapshot = WatchEntitlementSnapshot(
            kind: .trial,
            expiresAt: expiry,
            generatedAt: now
        )
        let newerExpiredSnapshot = WatchEntitlementSnapshot(
            kind: .trial,
            expiresAt: expiry,
            generatedAt: expiry
        )

        #expect(lastActiveSnapshot.canMutate(now: expiry.addingTimeInterval(3_600)))
        #expect(!newerExpiredSnapshot.canMutate(now: expiry))
    }

    @Test func snapshotBuilderMapsAuthoritativeIPhoneEntitlement() throws {
        let expiry = now.addingTimeInterval(600)

        let snapshot = try WatchSnapshotBuilder.make(
            projects: [],
            entitlement: .trial(
                startedAt: now.addingTimeInterval(-60),
                expiresAt: expiry
            ),
            locale: Locale(identifier: "en"),
            generatedAt: now
        )

        #expect(snapshot.schemaVersion == 2)
        #expect(snapshot.entitlement == WatchEntitlementSnapshot(
            kind: .trial,
            expiresAt: expiry,
            generatedAt: now
        ))
    }

    @Test func expiredSnapshotKeepsQueuedCommandForLaterEntitlementRetry() throws {
        let fixture = try WatchEntitlementFixture(
            entitlement: .init(
                kind: .trial,
                expiresAt: now.addingTimeInterval(60),
                generatedAt: now
            )
        )
        var state = WatchOptimisticState(cache: fixture.cache)

        #expect(state.enqueue(fixture.command, now: now) == nil)
        state.replaceSnapshot(try fixture.snapshot(
            entitlement: .init(
                kind: .trial,
                expiresAt: now,
                generatedAt: now.addingTimeInterval(1)
            )
        ))

        #expect(state.pendingCommands == [fixture.command])
        #expect(!state.canMutate(now: now.addingTimeInterval(1)))
        #expect(state.nextDeliverableCommand(now: now.addingTimeInterval(1)) == nil)

        state.replaceSnapshot(try fixture.snapshot(
            entitlement: .init(
                kind: .permanentlyUnlocked,
                expiresAt: nil,
                generatedAt: now.addingTimeInterval(2)
            )
        ))

        #expect(state.pendingCommands == [fixture.command])
        #expect(state.canMutate(now: now.addingTimeInterval(2)))
        #expect(
            state.nextDeliverableCommand(now: now.addingTimeInterval(2))
                == fixture.command
        )
    }

    @Test func expiredSnapshotRejectsNewOptimisticMutationWithoutSideEffects() throws {
        let fixture = try WatchEntitlementFixture(
            entitlement: .init(
                kind: .trial,
                expiresAt: now,
                generatedAt: now
            )
        )
        var state = WatchOptimisticState(cache: fixture.cache)
        let valueBefore = state.displayedValue(
            projectID: fixture.projectID,
            counterID: fixture.counterID
        )

        #expect(
            state.enqueue(fixture.command, now: now) == .entitlementRequired
        )
        #expect(state.pendingCommands.isEmpty)
        #expect(
            state.displayedValue(
                projectID: fixture.projectID,
                counterID: fixture.counterID
            ) == valueBefore
        )
    }

    @Test func entitlementRejectionCannotAcknowledgeOrDropQueuedCommand() throws {
        let fixture = try WatchEntitlementFixture(
            entitlement: .init(
                kind: .permanentlyUnlocked,
                expiresAt: nil,
                generatedAt: now
            )
        )
        var state = WatchOptimisticState(cache: fixture.cache)
        #expect(state.enqueue(fixture.command, now: now) == nil)

        let acknowledged = state.acknowledge(WatchCommandAcknowledgement(
            commandID: fixture.command.id,
            rejection: .entitlementRequired,
            snapshot: try fixture.snapshot(
                entitlement: .init(
                    kind: .trial,
                    expiresAt: now,
                    generatedAt: now.addingTimeInterval(1)
                )
            )
        ))

        #expect(!acknowledged)
        #expect(state.pendingCommands == [fixture.command])
        #expect(!state.canMutate(now: now.addingTimeInterval(1)))
    }
}

private struct WatchEntitlementFixture {
    let projectID = UUID()
    let counterID = UUID()
    let snapshot: WatchSyncSnapshot
    let command: WatchCounterCommand

    init(entitlement: WatchEntitlementSnapshot) throws {
        let counters = [
            WatchCounterSnapshot(id: counterID, name: "Counter 1", value: 4)
        ] + (2...6).map {
            WatchCounterSnapshot(id: UUID(), name: "Counter \($0)", value: 0)
        }
        snapshot = WatchSyncSnapshot(
            generatedAt: entitlement.generatedAt,
            entitlement: entitlement,
            projects: [try WatchProjectSnapshot(
                id: projectID,
                name: "Project",
                isCompleted: false,
                updatedAt: entitlement.generatedAt,
                counters: counters,
                selectedCounterID: counterID
            )]
        )
        command = WatchCounterCommand(
            id: UUID(),
            projectID: projectID,
            counterID: counterID,
            operation: .increment,
            createdAt: entitlement.generatedAt
        )
    }

    var cache: WatchSyncCache {
        WatchSyncCache(snapshot: snapshot, pendingCommands: [])
    }

    func snapshot(
        entitlement: WatchEntitlementSnapshot
    ) throws -> WatchSyncSnapshot {
        WatchSyncSnapshot(
            generatedAt: entitlement.generatedAt,
            entitlement: entitlement,
            projects: snapshot.projects
        )
    }
}
