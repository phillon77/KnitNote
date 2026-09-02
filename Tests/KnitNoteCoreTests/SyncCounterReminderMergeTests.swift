import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncCounterReminderMergeTests {
    @Test func legacyCounterOnlyAtomicPayloadDecodesIntoAggregate() throws {
        let counter = ProjectCounter(
            id: UUID(),
            defaultOrdinal: 1,
            value: 6,
            mutationRevision: 4
        )
        let counterObject = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(counter)
        ) as? [String: Any])
        let legacyBytes = try JSONSerialization.data(withJSONObject: [
            "projectCounter": ["_0": counterObject]
        ])

        let decoded = try JSONDecoder().decode(
            SyncAtomicDomainValue.self,
            from: legacyBytes
        )

        guard case let .projectCounter(state) = decoded else {
            Issue.record("Legacy counter did not migrate to the aggregate case")
            return
        }
        #expect(state.counter == counter)
        #expect(state.reminder == nil)
        #expect(state.preparedCommand == nil)
        #expect(state.processedCommandIDs.isEmpty)
        #expect(state.occurrence == nil)
    }

    @Test func legacyStandaloneReminderMigratesWithoutRemainingPublicationAuthority() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let baseReminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 4, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let reminder = try baseReminder.applying(.trigger(through: 0))
        let zeroStamp = stamp(revision: 0, deviceID: "legacy")
        let reminderStamp = stamp(
            revision: reminder.mutationRevision, deviceID: "legacy-reminder"
        )
        let reminderObject = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(reminder)
        ) as? [String: Any])
        let legacyAtomic = try JSONDecoder().decode(
            SyncAtomicDomainValue.self,
            from: JSONSerialization.data(withJSONObject: [
                "knittingReminder": ["_0": reminderObject]
            ])
        )
        guard case .knittingReminder = legacyAtomic else {
            Issue.record("Legacy standalone reminder did not decode")
            return
        }
        let counter = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID, stamp: zeroStamp
        )
        let legacyID = SyncEntityID(kind: .knittingReminder, uuid: reminder.id)
        let legacy = SyncRecord(
            schemaVersion: 1, id: legacyID, createdAt: reminder.createdAt,
            entityRevision: reminder.mutationRevision,
            payload: .init(fields: [:], atomicDomain: .init(
                value: legacyAtomic, stamp: reminderStamp
            )),
            relationships: [.init(
                role: "counter", target: .init(kind: .projectCounter, uuid: counterID)
            )],
            deletedAt: .init(value: nil, stamp: reminderStamp)
        )

        let result = try SyncMergeEngine().merge(
            local: [counter], remote: [legacy], pendingLocal: [legacyID]
        )

        #expect(result.records.map(\.id) == [.init(kind: .projectCounter, uuid: counterID)])
        #expect(result.records[0].counterReminderState?.reminders.map(\.id) == [reminder.id])
        #expect(result.recordsToUpload == [.init(kind: .projectCounter, uuid: counterID)])
        #expect(result.mutationsToUpload.allSatisfy { $0.recordID.kind != .knittingReminder })
        #expect(throws: (any Error).self) {
            _ = try JSONEncoder().encode(SyncAtomicDomainValue.knittingReminder(reminder))
        }
    }

    @Test func processedCommandIDsEncodeInStableLexicalOrder() throws {
        let ids = [
            try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
            try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
        ]
        let aggregate = state(
            counterID: UUID(),
            value: 1,
            counterRevision: 1,
            processedCommandIDs: Set(ids)
        )

        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(aggregate)
        ) as? [String: Any])
        let encodedIDs = try #require(object["processedCommandIDs"] as? [String])

        #expect(encodedIDs == ids.map(\.uuidString).sorted())
    }

    @Test func divergentEqualStampAtomicStatesAlwaysThrowForEveryPermutation() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let entityID = SyncEntityID(kind: .projectCounter, uuid: counterID)
        let stamp = SyncMutationStamp(
            logicalRevision: 7,
            modifiedAt: Date(timeIntervalSince1970: 7),
            deviceID: "same-device"
        )
        let first = record(
            state: state(counterID: counterID, value: 4, counterRevision: 3),
            projectID: projectID,
            stamp: stamp
        )
        let second = record(
            state: state(counterID: counterID, value: 9, counterRevision: 3),
            projectID: projectID,
            stamp: stamp
        )

        for (local, remote) in [(first, second), (second, first)] {
            #expect(throws: SyncMergeError.corruptEqualStamp(
                entity: entityID,
                field: "counterReminderState"
            )) {
                _ = try SyncMergeEngine().merge(
                    local: [local],
                    remote: [remote],
                    pendingLocal: []
                )
            }
        }
    }

    @Test func newerAtomicStateWinsWithoutAddingConcurrentAbsoluteCounterValues() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let older = record(
            state: state(counterID: counterID, value: 12, counterRevision: 8),
            projectID: projectID,
            stamp: stamp(revision: 10, deviceID: "older")
        )
        let newer = record(
            state: state(counterID: counterID, value: 30, counterRevision: 8),
            projectID: projectID,
            stamp: stamp(revision: 11, deviceID: "newer")
        )

        let result = try SyncMergeEngine().merge(
            local: [older],
            remote: [newer],
            pendingLocal: []
        )

        #expect(result.records.count == 1)
        #expect(result.records[0].counterReminderState?.counter.value == 30)
        #expect(result.records[0].entityRevision == 11)
    }

    @Test func newerAggregateCanRemoveAnOlderReminder() throws {
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(),
            counterID: counterID,
            draft: .oneTime(kind: .measure, target: 4, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let older = state(
            counterID: counterID,
            value: 2,
            counterRevision: 2,
            reminder: reminder
        )
        let removed = state(counterID: counterID, value: 2, counterRevision: 2)

        let merged = try SyncCounterReminderMergePolicy().merge(
            .init(value: older, stamp: stamp(revision: 4, deviceID: "older")),
            .init(value: removed, stamp: stamp(revision: 5, deviceID: "newer")),
            context: .init()
        )

        #expect(merged.value.reminder == nil)
    }

    @Test func aggregatePreservesEveryReminderInStableIdentityOrder() throws {
        let counterID = UUID()
        let first = try #require(KnittingReminder(
            id: UUID(),
            counterID: counterID,
            draft: .oneTime(kind: .cable, target: 4, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let second = try #require(KnittingReminder(
            id: UUID(),
            counterID: counterID,
            draft: .oneTime(kind: .measure, target: 8, text: nil),
            createdAt: Date(timeIntervalSince1970: 2)
        ))

        let aggregate = SyncCounterReminderState(
            counter: ProjectCounter(id: counterID, defaultOrdinal: 1),
            reminders: [second, first],
            preparedCommand: nil,
            processedCommandIDs: [],
            occurrence: nil
        )

        #expect(aggregate.reminders.map(\.id) == [first.id, second.id].sorted {
            $0.uuidString < $1.uuidString
        })
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let merged = try SyncMergeEngine().merge(
            local: [record(
                state: aggregate, projectID: projectID,
                stamp: stamp(revision: 1, deviceID: "local")
            )],
            remote: [record(
                state: aggregate, projectID: projectID,
                stamp: stamp(revision: 2, deviceID: "remote")
            )],
            pendingLocal: []
        )
        #expect(merged.records[0].counterReminderState?.reminders.map(\.id)
            == aggregate.reminders.map(\.id))
    }

    @Test func aggregateValidatorRejectsDuplicateOrForeignReminderOwnership() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 2, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let duplicate = SyncCounterReminderState(
            counter: ProjectCounter(id: counterID, defaultOrdinal: 1),
            reminders: [reminder, reminder], preparedCommand: nil,
            processedCommandIDs: [], occurrence: nil
        )
        let foreign = try #require(KnittingReminder(
            id: UUID(), counterID: UUID(),
            draft: .oneTime(kind: .cable, target: 3, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let foreignOwner = SyncCounterReminderState(
            counter: ProjectCounter(id: counterID, defaultOrdinal: 1),
            reminders: [reminder, foreign], preparedCommand: nil,
            processedCommandIDs: [], occurrence: nil
        )
        let expected = SyncRecordValidationError.illegalAtomicDomain(
            .init(kind: .projectCounter, uuid: counterID)
        )

        for invalid in [duplicate, foreignOwner] {
            #expect(throws: expected) {
                _ = try SyncRecordValidator().validate(record(
                    state: invalid, projectID: projectID,
                    stamp: stamp(revision: 0, deviceID: "validation")
                ))
            }
        }
    }

    @Test func causalWinnerCannotRollBackCounterMutationRevision() {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let current = record(
            state: state(counterID: counterID, value: 12, counterRevision: 8),
            projectID: projectID,
            stamp: stamp(revision: 10, deviceID: "older")
        )
        let rollback = record(
            state: state(counterID: counterID, value: 3, counterRevision: 7),
            projectID: projectID,
            stamp: stamp(revision: 11, deviceID: "newer")
        )

        #expect(throws: SyncMergeError.corruptAtomicDomain(
            entity: .init(kind: .projectCounter, uuid: counterID),
            revision: 7
        )) {
            _ = try SyncMergeEngine().merge(
                local: [current],
                remote: [rollback],
                pendingLocal: []
            )
        }
    }

    @Test func interveningCounterRollbackThrowsForEveryCandidatePermutation() {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let records = [
            record(
                state: state(counterID: counterID, value: 5, counterRevision: 5),
                projectID: projectID,
                stamp: stamp(revision: 10, deviceID: "first")
            ),
            record(
                state: state(counterID: counterID, value: 4, counterRevision: 4),
                projectID: projectID,
                stamp: stamp(revision: 11, deviceID: "rollback")
            ),
            record(
                state: state(counterID: counterID, value: 6, counterRevision: 6),
                projectID: projectID,
                stamp: stamp(revision: 12, deviceID: "last")
            ),
        ]
        let expected = SyncMergeError.corruptAtomicDomain(
            entity: .init(kind: .projectCounter, uuid: counterID),
            revision: 4
        )

        for permutation in permutations(of: records) {
            #expect(throws: expected) {
                _ = try SyncMergeEngine().merge(
                    local: permutation,
                    remote: [],
                    pendingLocal: []
                )
            }
        }
    }

    @Test func compatibleProcessedCommandIDsAreMonotonicallyUnioned() throws {
        let projectID = UUID()
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(),
            projectID: projectID,
            counterID: counterID,
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command,
            expectedCounterRevision: 4,
            expectedCounterValue: 9
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, at: Date(timeIntervalSince1970: 2))
        let olderState = state(
            counterID: counterID,
            value: 10,
            counterRevision: 5,
            processedCommandIDs: [command.id]
        )
        let newerState = state(counterID: counterID, value: 10, counterRevision: 5)

        let merged = try SyncCounterReminderMergePolicy().merge(
            .init(value: olderState, stamp: stamp(revision: 10, deviceID: "older")),
            .init(value: newerState, stamp: stamp(revision: 11, deviceID: "newer")),
            context: .init(preparedCommands: [prepared], processedLedger: ledger)
        )

        #expect(merged.stamp.logicalRevision == 11)
        #expect(merged.value.processedCommandIDs == [command.id])
        #expect(merged.value.counter.value == 10)
    }

    @Test func unprovenProcessedCommandRegressionIsRejected() {
        let counterID = UUID()
        let commandID = UUID()
        let older = state(
            counterID: counterID,
            value: 4,
            counterRevision: 4,
            processedCommandIDs: [commandID]
        )
        let newer = state(counterID: counterID, value: 4, counterRevision: 4)

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(commandID)) {
            _ = try SyncCounterReminderMergePolicy().merge(
                .init(value: older, stamp: stamp(revision: 4, deviceID: "older")),
                .init(value: newer, stamp: stamp(revision: 5, deviceID: "newer")),
                context: .init()
            )
        }
    }

    @Test func differentCounterOperationAtExpectedRevisionCannotProveReceipt() {
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 4, expectedCounterValue: 9
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, preparedCommand: prepared, at: Date(timeIntervalSince1970: 2))

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncCounterReminderMergePolicy().merge(
                .init(value: state(counterID: counterID, value: 10, counterRevision: 5,
                    processedCommandIDs: [command.id]), stamp: stamp(revision: 5, deviceID: "old")),
                .init(value: state(counterID: counterID, value: 8, counterRevision: 5),
                    stamp: stamp(revision: 6, deviceID: "new")),
                context: .init(processedLedger: ledger)
            )
        }
    }

    @Test func deferCannotProvePreparedCompleteReceipt() throws {
        let counterID = UUID()
        let base = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let triggered = try base.applying(.trigger(through: 1))
        let occurrence = try #require(triggered.progress.pending.first)
        let deferred = try triggered.applying(.deferOnce(
            occurrenceID: occurrence.id, observedRevision: triggered.mutationRevision
        ))
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: counterID,
            operation: .completeReminder, reminderID: triggered.id,
            occurrenceID: occurrence.id,
            observedMutationRevision: triggered.mutationRevision,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 1, expectedCounterValue: 1,
            expectedReminderID: triggered.id, expectedOccurrenceID: occurrence.id,
            expectedReminderRevision: triggered.mutationRevision,
            expectedReminderOutcome: .init(
                action: .complete, completedCount: 1, skippedCount: 0
            )
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, preparedCommand: prepared, at: Date(timeIntervalSince1970: 3))

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncCounterReminderMergePolicy().merge(
                .init(value: state(counterID: counterID, value: 1, counterRevision: 1,
                    reminder: triggered, processedCommandIDs: [command.id]),
                    stamp: stamp(revision: 4, deviceID: "old")),
                .init(value: state(counterID: counterID, value: 1, counterRevision: 1,
                    reminder: deferred), stamp: stamp(revision: 5, deviceID: "new")),
                context: .init(processedLedger: ledger)
            )
        }
    }

    @Test func completeCannotProvePreparedDeferOrSkipReceipts() throws {
        let counterID = UUID()
        let base = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let triggered = try base.applying(.trigger(through: 1))
        let occurrence = try #require(triggered.progress.pending.first)
        let completed = try triggered.applying(.complete(
            occurrenceID: occurrence.id, observedRevision: triggered.mutationRevision
        ))
        let cases: [(WatchCounterOperation, PreparedWatchReminderOutcome)] = [
            (.deferReminderOnce, .init(
                action: .deferOnce, completedCount: 0, skippedCount: 0,
                deferredDisplayAt: 2
            )),
            (.skipReminder, .init(
                action: .skip, completedCount: 0, skippedCount: 1
            )),
        ]

        for (operation, outcome) in cases {
            let command = WatchCounterCommand(
                id: UUID(), projectID: UUID(), counterID: counterID,
                operation: operation, reminderID: triggered.id,
                occurrenceID: occurrence.id,
                observedMutationRevision: triggered.mutationRevision,
                createdAt: Date(timeIntervalSince1970: 2)
            )
            let prepared = PreparedWatchCommand(
                command: command, expectedCounterRevision: 1, expectedCounterValue: 1,
                expectedReminderID: triggered.id, expectedOccurrenceID: occurrence.id,
                expectedReminderRevision: triggered.mutationRevision,
                expectedReminderOutcome: outcome
            )
            var ledger = ProcessedWatchCommandLedger()
            ledger.record(command.id, preparedCommand: prepared, at: Date(timeIntervalSince1970: 3))
            #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
                _ = try SyncCounterReminderMergePolicy().merge(
                    .init(value: state(counterID: counterID, value: 1, counterRevision: 1,
                        reminder: triggered, processedCommandIDs: [command.id]),
                        stamp: stamp(revision: 4, deviceID: "old")),
                    .init(value: state(counterID: counterID, value: 1, counterRevision: 1,
                        reminder: completed), stamp: stamp(revision: 5, deviceID: "new")),
                    context: .init(processedLedger: ledger)
                )
            }
        }
    }

    @Test func ledgeredStopReturnsPersistedOrNoOpWithoutThrowing() throws {
        let projectID = UUID()
        let counterID = UUID()
        let reminderID = UUID()
        let base = try #require(KnittingReminder(
            id: reminderID,
            counterID: counterID,
            draft: .oneTime(kind: .cable, target: 1, text: "Cable"),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let triggered = try base.applying(.trigger(through: 1))
        let occurrence = try #require(triggered.progress.pending.first)
        let command = WatchCounterCommand(
            schemaVersion: 2,
            id: UUID(),
            projectID: projectID,
            counterID: counterID,
            operation: .stopReminder,
            reminderID: reminderID,
            occurrenceID: occurrence.id,
            observedMutationRevision: triggered.mutationRevision,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let prepared = PreparedWatchCommand(
            command: command,
            expectedCounterRevision: 4,
            expectedCounterValue: 1,
            expectedReminderID: reminderID,
            expectedOccurrenceID: occurrence.id,
            expectedReminderRevision: triggered.mutationRevision
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, at: Date(timeIntervalSince1970: 3))
        let initial = SyncCounterReminderState(
            counter: ProjectCounter(
                id: counterID,
                defaultOrdinal: 1,
                value: 1,
                mutationRevision: 4
            ),
            reminder: triggered,
            preparedCommand: prepared,
            processedCommandIDs: [],
            occurrence: triggered.progress.nextOccurrenceIndex
        )
        let policy = SyncCounterReminderMergePolicy()

        let first = try policy.applyingStop(
            prepared,
            to: initial,
            processedLedger: ledger
        )
        let replay = try policy.applyingStop(
            prepared,
            to: first.state,
            processedLedger: ledger
        )
        let productionMerge = try policy.merge(
            .init(value: initial, stamp: stamp(revision: 4, deviceID: "older")),
            .init(value: initial, stamp: stamp(revision: 5, deviceID: "winner")),
            context: .init(preparedCommands: [prepared], processedLedger: ledger)
        )

        #expect(first.isPersisted)
        #expect(replay.isNoOp)
        #expect(first.state.reminder?.state == .stopped)
        #expect(first.state.processedCommandIDs == replay.state.processedCommandIDs)
        #expect(first.state.processedCommandIDs == [command.id])
        #expect(productionMerge.value.reminders.first?.state == .stopped)
        #expect(productionMerge.value.processedCommandIDs == [command.id])
    }
}

private func state(
    counterID: UUID,
    value: Int,
    counterRevision: UInt64,
    reminder: KnittingReminder? = nil,
    preparedCommand: PreparedWatchCommand? = nil,
    processedCommandIDs: Set<UUID> = []
) -> SyncCounterReminderState {
    SyncCounterReminderState(
        counter: ProjectCounter(
            id: counterID,
            defaultOrdinal: 1,
            value: value,
            mutationRevision: counterRevision
        ),
        reminder: reminder,
        preparedCommand: preparedCommand,
        processedCommandIDs: processedCommandIDs,
        occurrence: reminder?.progress.nextOccurrenceIndex
    )
}

private func record(
    state: SyncCounterReminderState,
    projectID: SyncEntityID,
    stamp: SyncMutationStamp
) -> SyncRecord {
    SyncRecord(
        schemaVersion: 1,
        id: .init(kind: .projectCounter, uuid: state.counter.id),
        createdAt: Date(timeIntervalSince1970: 0),
        entityRevision: stamp.logicalRevision,
        payload: .init(
            fields: [:],
            atomicDomain: .init(value: .projectCounter(state), stamp: stamp)
        ),
        relationships: [.init(role: "project", target: projectID)],
        deletedAt: .init(value: nil, stamp: stamp)
    )
}

private func stamp(revision: UInt64, deviceID: String) -> SyncMutationStamp {
    SyncMutationStamp(
        logicalRevision: revision,
        modifiedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
        deviceID: deviceID
    )
}

private func permutations<T>(of values: [T]) -> [[T]] {
    guard let first = values.first else { return [[]] }
    return permutations(of: Array(values.dropFirst())).flatMap { tail in
        (0...tail.count).map { index in
            var result = tail
            result.insert(first, at: index)
            return result
        }
    }
}

private extension SyncRecord {
    var counterReminderState: SyncCounterReminderState? {
        guard case let .projectCounter(state)? = payload.atomicDomain?.value else { return nil }
        return state
    }
}
