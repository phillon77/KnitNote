import CryptoKit
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

    @Test func splitLegacyRemindersUnionBeforeCounterAggregateMerge() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let first = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 3, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let secondBase = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 6, text: nil),
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        let second = try secondBase.applying(.trigger(through: 0))
        let aggregateStamp = stamp(revision: 0, deviceID: "aggregate-older")
        let standaloneStamp = stamp(revision: 1, deviceID: "legacy-newer")
        let aggregate = record(
            state: SyncCounterReminderState(
                counter: ProjectCounter(id: counterID, defaultOrdinal: 1),
                reminders: [first], preparedCommand: nil,
                processedCommandIDs: [], occurrence: nil
            ),
            projectID: projectID,
            stamp: aggregateStamp
        )
        let standalone = legacyReminderRecord(reminder: second, stamp: standaloneStamp)

        let result = try SyncMergeEngine().merge(
            local: [aggregate], remote: [standalone], pendingLocal: []
        )

        #expect(Set(result.records[0].counterReminderState?.reminders.map(\.id) ?? [])
            == [first.id, second.id])
        #expect(result.records.allSatisfy { $0.id.kind != .knittingReminder })
        #expect(result.recordsToUpload == [.init(kind: .projectCounter, uuid: counterID)])
    }

    @Test func staleLiveLegacyReminderCannotResurrectNewerAggregate() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 3, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let aggregate = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 2, deviceID: "aggregate-newer")
        )
        let stale = legacyReminderRecord(
            reminder: reminder,
            stamp: stamp(revision: 0, deviceID: "legacy-older")
        )

        let result = try SyncMergeEngine().merge(
            local: [aggregate], remote: [stale], pendingLocal: []
        )

        #expect(result.records[0].counterReminderState?.reminders.isEmpty == true)
    }

    @Test func newerLegacyReminderReplacesOlderAggregateReminder() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let base = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let triggered = try base.applying(.trigger(through: 1))
        let aggregate = record(
            state: SyncCounterReminderState(
                counter: ProjectCounter(id: counterID, defaultOrdinal: 1),
                reminders: [base], preparedCommand: nil,
                processedCommandIDs: [], occurrence: nil
            ),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "aggregate-older")
        )
        let newer = legacyReminderRecord(
            reminder: triggered,
            stamp: stamp(revision: 1, deviceID: "legacy-newer")
        )

        let result = try SyncMergeEngine().merge(
            local: [aggregate], remote: [newer], pendingLocal: []
        )

        #expect(result.records[0].counterReminderState?.reminders == [triggered])
    }

    @Test func equalStampDivergentLegacyAndAggregateReminderIsCorrupt() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let base = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .changeYarn, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let triggered = try base.applying(.trigger(through: 1))
        let equalStamp = stamp(revision: 1, deviceID: "equal")
        let aggregate = record(
            state: SyncCounterReminderState(
                counter: ProjectCounter(id: counterID, defaultOrdinal: 1),
                reminders: [base], preparedCommand: nil,
                processedCommandIDs: [], occurrence: nil
            ),
            projectID: projectID,
            stamp: equalStamp
        )
        let standalone = legacyReminderRecord(reminder: triggered, stamp: equalStamp)

        #expect(throws: SyncMergeError.corruptEqualStamp(
            entity: .init(kind: .knittingReminder, uuid: base.id),
            field: "counterReminderState"
        )) {
            _ = try SyncMergeEngine().merge(
                local: [aggregate], remote: [standalone], pendingLocal: []
            )
        }
    }

    @Test func consumedRemoteLegacyReminderSurfacesDeletionIntentOnEveryRepeat() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 2, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let aggregate = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "aggregate")
        )
        let standalone = legacyReminderRecord(
            reminder: try reminder.applying(.trigger(through: 0)),
            stamp: stamp(revision: 1, deviceID: "legacy")
        )

        let first = try SyncMergeEngine().merge(
            local: [aggregate], remote: [standalone], pendingLocal: []
        )
        let repeated = try SyncMergeEngine().merge(
            local: first.records, remote: [standalone], pendingLocal: []
        )

        #expect(first.legacyRecordIDsToDelete == [standalone.id])
        #expect(repeated.legacyRecordIDsToDelete == [standalone.id])
        #expect(repeated.records == first.records)
        #expect(repeated.records.allSatisfy { $0.id.kind != .knittingReminder })
    }

    @Test func tombstonedLegacyReminderDoesNotResurrectIntoAggregate() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let base = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .changeYarn, target: 2, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let reminder = try base.applying(.trigger(through: 0))
        let liveStamp = stamp(revision: reminder.mutationRevision, deviceID: "live")
        let tombstoneStamp = stamp(revision: 2, deviceID: "tombstone")
        let aggregate = record(
            state: SyncCounterReminderState(
                counter: ProjectCounter(id: counterID, defaultOrdinal: 1),
                reminders: [reminder], preparedCommand: nil,
                processedCommandIDs: [], occurrence: nil
            ),
            projectID: projectID,
            stamp: liveStamp
        )
        let tombstone = legacyReminderRecord(
            reminder: reminder,
            stamp: liveStamp,
            deletedAt: .init(
                value: Date(timeIntervalSince1970: 2), stamp: tombstoneStamp
            )
        )

        let result = try SyncMergeEngine().merge(
            local: [aggregate], remote: [tombstone], pendingLocal: []
        )

        #expect(result.records[0].counterReminderState?.reminders.isEmpty == true)
        #expect(result.records.allSatisfy { $0.id.kind != .knittingReminder })
    }

    @Test func pendingLegacyDeleteBecomesExactCounterAggregateMutation() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 2, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let aggregate = record(
            state: SyncCounterReminderState(
                counter: ProjectCounter(id: counterID, defaultOrdinal: 1),
                reminders: [reminder], preparedCommand: nil,
                processedCommandIDs: [], occurrence: nil
            ),
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "aggregate")
        )
        let legacy = legacyReminderRecord(
            reminder: reminder, stamp: stamp(revision: 0, deviceID: "legacy")
        )
        let mutationID = UUID()

        let result = try SyncMergeEngine().merge(
            local: [aggregate], remote: [legacy],
            pendingLocalMutations: [.delete(legacy.id, mutationID: mutationID)]
        )

        #expect(result.records[0].counterReminderState?.reminders.isEmpty == true)
        #expect(result.mutationsToUpload.count == 1)
        #expect(result.mutationsToUpload[0].recordID
            == .init(kind: .projectCounter, uuid: counterID))
        #expect(result.mutationsToUpload[0].mutationID == mutationID)
        #expect(result.mutationsToUpload[0].savedRecordVersion?.record
            .counterReminderState?.reminders.isEmpty == true)
    }

    @Test func pendingLegacySaveBecomesExactCounterAggregateMutation() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 5, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let zeroStamp = stamp(revision: 0, deviceID: "legacy-save")
        let aggregate = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: zeroStamp
        )
        let mutationID = UUID()
        let legacySave = try decodedLegacySaveMutation(
            reminder: reminder,
            projectID: projectID,
            stamp: zeroStamp,
            mutationID: mutationID
        )

        let result = try SyncMergeEngine().merge(
            local: [aggregate], remote: [],
            pendingLocalMutations: [legacySave]
        )

        #expect(result.records[0].counterReminderState?.reminders.map(\.id) == [reminder.id])
        #expect(result.mutationsToUpload.count == 1)
        let converted = try #require(result.mutationsToUpload.first)
        #expect(converted.recordID == .init(kind: .projectCounter, uuid: counterID))
        #expect(converted.mutationID == mutationID)
        #expect(converted.savedRecordVersion?.record.counterReminderState?
            .reminders.map(\.id) == [reminder.id])
    }

    @Test func pendingLegacySaveThenDeletePreservesBothExactAggregateIntents() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 7, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let zeroStamp = stamp(revision: 0, deviceID: "legacy-sequence")
        let aggregate = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: zeroStamp
        )
        let saveID = UUID()
        let deleteID = UUID()
        let save = try decodedLegacySaveMutation(
            reminder: reminder,
            projectID: projectID,
            stamp: zeroStamp,
            mutationID: saveID
        )

        let result = try SyncMergeEngine().merge(
            local: [aggregate], remote: [],
            pendingLocalMutations: [
                save,
                .delete(
                    .init(kind: .knittingReminder, uuid: reminder.id),
                    mutationID: deleteID
                ),
            ]
        )

        #expect(result.records[0].counterReminderState?.reminders.isEmpty == true)
        #expect(result.mutationsToUpload.map(\.mutationID) == [saveID, deleteID])
        #expect(result.mutationsToUpload[0].savedRecordVersion?.record
            .counterReminderState?.reminders.map(\.id) == [reminder.id])
        #expect(result.mutationsToUpload[1].savedRecordVersion?.record
            .counterReminderState?.reminders.isEmpty == true)
    }

    @Test func pendingLegacyMutationsProduceCumulativeCausallyOrderedSnapshots() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let firstBase = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let secondBase = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        let first = try firstBase.applying(.trigger(through: 0))
        let second = try secondBase.applying(.trigger(through: 0))
        let aggregate = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "aggregate")
        )
        let firstSaveID = UUID()
        let secondSaveID = UUID()
        let deleteID = UUID()
        let firstStamp = stamp(revision: 1, deviceID: "legacy-first")
        let secondStamp = stamp(revision: 1, deviceID: "legacy-second")
        let firstSave = try decodedLegacySaveMutation(
            reminder: first, projectID: projectID,
            stamp: firstStamp,
            mutationID: firstSaveID
        )
        let secondSave = try decodedLegacySaveMutation(
            reminder: second, projectID: projectID,
            stamp: secondStamp,
            mutationID: secondSaveID
        )

        let result = try SyncMergeEngine().merge(
            local: [aggregate], remote: [],
            pendingLocalMutations: [
                firstSave,
                secondSave,
                .delete(
                    .init(kind: .knittingReminder, uuid: first.id),
                    mutationID: deleteID
                ),
            ]
        )

        let snapshots = result.mutationsToUpload.compactMap {
            $0.savedRecordVersion?.record
        }
        let snapshotReminderIDs: [[UUID]] = snapshots.map {
            $0.counterReminderState?.reminders.map(\.id) ?? []
        }
        let expectedSecondSnapshot = [first.id, second.id].sorted {
            $0.uuidString < $1.uuidString
        }
        #expect(result.mutationsToUpload.map(\.mutationID)
            == [firstSaveID, secondSaveID, deleteID])
        #expect(snapshotReminderIDs == [
            [first.id],
            expectedSecondSnapshot,
            [second.id],
        ])
        let snapshotStamps = snapshots.compactMap { $0.payload.atomicDomain?.stamp }
        #expect(snapshotStamps[0] == firstStamp)
        #expect(snapshotStamps[1] == secondStamp)
        #expect(snapshotStamps[2].logicalRevision == 2)
        #expect(snapshotStamps[2].deviceID
            == "legacy-reminder-mutation-\(deleteID.uuidString.lowercased())")
        #expect(snapshotStamps[0] < snapshotStamps[1])
        #expect(snapshotStamps[1] < snapshotStamps[2])
        #expect(result.records[0].counterReminderState?.reminders.map(\.id) == [second.id])
    }

    @Test func legacyPendingSaveBeforeCanonicalCounterSaveKeepsEarlierSnapshot() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 3, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let base = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "base")
        )
        let legacyID = UUID()
        let legacySave = try decodedLegacySaveMutation(
            reminder: reminder,
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "legacy"),
            mutationID: legacyID
        )
        let laterRecord = record(
            state: SyncCounterReminderState(
                counter: ProjectCounter(
                    id: counterID, defaultOrdinal: 1,
                    value: 7, mutationRevision: 1
                ),
                reminders: [reminder], preparedCommand: nil,
                processedCommandIDs: [], occurrence: nil
            ),
            projectID: projectID,
            stamp: stamp(revision: 2, deviceID: "canonical-later")
        )
        let canonicalID = UUID()
        let canonicalSave = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: laterRecord),
            mutationID: canonicalID
        )

        let result = try SyncMergeEngine().merge(
            local: [base], remote: [],
            pendingLocalMutations: [legacySave, canonicalSave]
        )

        #expect(result.mutationsToUpload.map(\.mutationID) == [legacyID, canonicalID])
        let legacySnapshot = try #require(
            result.mutationsToUpload[0].savedRecordVersion?.record.counterReminderState
        )
        #expect(legacySnapshot.counter.value == 0)
        #expect(legacySnapshot.reminders.map(\.id) == [reminder.id])
        #expect(result.mutationsToUpload[1] == canonicalSave)
        let visible = try #require(result.records.first { $0.id == laterRecord.id })
        #expect(visible.counterReminderState?.counter.value == 7)
        #expect(visible.counterReminderState?.reminders.map(\.id) == [reminder.id])
    }

    @Test func canonicalPendingSaveBeforeLegacyUsesStateAtItsJournalPosition() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 4, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let base = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "base")
        )
        let firstRecord = record(
            state: state(counterID: counterID, value: 3, counterRevision: 1),
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "canonical-first")
        )
        let firstID = UUID()
        let firstSave = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: firstRecord),
            mutationID: firstID
        )
        let legacyID = UUID()
        let legacySave = try decodedLegacySaveMutation(
            reminder: reminder,
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "legacy"),
            mutationID: legacyID
        )
        let lastRecord = record(
            state: SyncCounterReminderState(
                counter: ProjectCounter(
                    id: counterID, defaultOrdinal: 1,
                    value: 9, mutationRevision: 2
                ),
                reminders: [reminder], preparedCommand: nil,
                processedCommandIDs: [], occurrence: nil
            ),
            projectID: projectID,
            stamp: stamp(revision: 3, deviceID: "canonical-last")
        )
        let lastID = UUID()
        let lastSave = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: lastRecord),
            mutationID: lastID
        )

        let result = try SyncMergeEngine().merge(
            local: [base], remote: [],
            pendingLocalMutations: [firstSave, legacySave, lastSave]
        )

        #expect(result.mutationsToUpload.map(\.mutationID) == [firstID, legacyID, lastID])
        #expect(result.mutationsToUpload[0] == firstSave)
        let legacySnapshot = try #require(
            result.mutationsToUpload[1].savedRecordVersion?.record.counterReminderState
        )
        #expect(legacySnapshot.counter.value == 3)
        #expect(legacySnapshot.reminders.map(\.id) == [reminder.id])
        #expect(result.mutationsToUpload[2] == lastSave)
        let visible = try #require(result.records.first { $0.id == lastRecord.id })
        #expect(visible.counterReminderState?.counter.value == 9)
    }

    @Test func interleavedPendingMutationsReplayEachCounterIndependently() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let firstCounterID = UUID()
        let secondCounterID = UUID()
        let firstReminder = try #require(KnittingReminder(
            id: UUID(), counterID: firstCounterID,
            draft: .oneTime(kind: .cable, target: 2, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let secondReminder = try #require(KnittingReminder(
            id: UUID(), counterID: secondCounterID,
            draft: .oneTime(kind: .measure, target: 5, text: nil),
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        let firstBase = record(
            state: state(counterID: firstCounterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "first-base")
        )
        let secondBase = record(
            state: state(counterID: secondCounterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "second-base")
        )
        let firstLegacyID = UUID()
        let firstLegacySave = try decodedLegacySaveMutation(
            reminder: firstReminder,
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "first-legacy"),
            mutationID: firstLegacyID
        )
        let secondCanonicalRecord = record(
            state: state(counterID: secondCounterID, value: 2, counterRevision: 1),
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "second-canonical")
        )
        let secondCanonicalID = UUID()
        let secondCanonicalSave = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: secondCanonicalRecord),
            mutationID: secondCanonicalID
        )
        let firstCanonicalRecord = record(
            state: SyncCounterReminderState(
                counter: ProjectCounter(
                    id: firstCounterID, defaultOrdinal: 1,
                    value: 1, mutationRevision: 1
                ),
                reminders: [firstReminder], preparedCommand: nil,
                processedCommandIDs: [], occurrence: nil
            ),
            projectID: projectID,
            stamp: stamp(revision: 2, deviceID: "first-canonical")
        )
        let firstCanonicalID = UUID()
        let firstCanonicalSave = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: firstCanonicalRecord),
            mutationID: firstCanonicalID
        )
        let secondLegacyID = UUID()
        let secondLegacySave = try decodedLegacySaveMutation(
            reminder: secondReminder,
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "second-legacy"),
            mutationID: secondLegacyID
        )

        let result = try SyncMergeEngine().merge(
            local: [firstBase, secondBase], remote: [],
            pendingLocalMutations: [
                firstLegacySave,
                secondCanonicalSave,
                firstCanonicalSave,
                secondLegacySave,
            ]
        )

        #expect(result.mutationsToUpload.map(\.mutationID) == [
            firstLegacyID,
            secondCanonicalID,
            firstCanonicalID,
            secondLegacyID,
        ])
        let firstLegacySnapshot = try #require(
            result.mutationsToUpload[0].savedRecordVersion?.record.counterReminderState
        )
        #expect(firstLegacySnapshot.counter.value == 0)
        #expect(firstLegacySnapshot.reminders.map(\.id) == [firstReminder.id])
        #expect(result.mutationsToUpload[1] == secondCanonicalSave)
        #expect(result.mutationsToUpload[2] == firstCanonicalSave)
        let secondLegacySnapshot = try #require(
            result.mutationsToUpload[3].savedRecordVersion?.record.counterReminderState
        )
        #expect(secondLegacySnapshot.counter.value == 2)
        #expect(secondLegacySnapshot.reminders.map(\.id) == [secondReminder.id])
    }

    @Test func canonicalSaveThenDeleteAdvancesRollingVisibleStateInOrder() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let counterRecordID = SyncEntityID(kind: .projectCounter, uuid: counterID)
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .changeYarn, target: 6, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let base = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "base")
        )
        let savedRecord = record(
            state: state(counterID: counterID, value: 1, counterRevision: 1),
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "canonical-save")
        )
        let saveID = UUID()
        let canonicalSave = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: savedRecord),
            mutationID: saveID
        )
        let legacyID = UUID()
        let legacySave = try decodedLegacySaveMutation(
            reminder: reminder,
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "legacy"),
            mutationID: legacyID
        )
        let deleteID = UUID()
        let canonicalDelete = SyncMutation.delete(
            counterRecordID,
            mutationID: deleteID
        )

        let result = try SyncMergeEngine().merge(
            local: [base], remote: [],
            pendingLocalMutations: [canonicalSave, legacySave, canonicalDelete]
        )

        #expect(result.mutationsToUpload.map(\.mutationID) == [saveID, legacyID, deleteID])
        #expect(result.mutationsToUpload.map(\.intent) == [.save, .save, .delete])
        #expect(result.mutationsToUpload[0] == canonicalSave)
        let legacySnapshot = try #require(
            result.mutationsToUpload[1].savedRecordVersion?.record.counterReminderState
        )
        #expect(legacySnapshot.counter.value == 1)
        #expect(legacySnapshot.reminders.map(\.id) == [reminder.id])
        #expect(result.mutationsToUpload[2] == canonicalDelete)
        #expect(!result.records.contains { $0.id == counterRecordID })
    }

    @Test func pendingOnlyCanonicalCounterSavesStillSurfaceAtomicConflict() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let counterRecordID = SyncEntityID(kind: .projectCounter, uuid: counterID)
        let firstRecord = record(
            state: state(counterID: counterID, value: 1, counterRevision: 1),
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "first")
        )
        let secondRecord = record(
            state: state(counterID: counterID, value: 2, counterRevision: 1),
            projectID: projectID,
            stamp: stamp(revision: 2, deviceID: "second")
        )
        let firstSave = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: firstRecord),
            mutationID: UUID()
        )
        let secondSave = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: secondRecord),
            mutationID: UUID()
        )

        let result = try SyncMergeEngine().merge(
            local: [], remote: [],
            pendingLocalMutations: [firstSave, secondSave]
        )

        #expect(result.records.first?.counterReminderState?.counter.value == 2)
        #expect(result.conflicts == [
            .counterValues(entity: counterRecordID, revision: 1, values: [1, 2]),
        ])
    }

    @Test func pendingLegacyDeleteCannotBorrowIdentityFromLaterSave() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .measure, target: 2, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let aggregate = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: stamp(revision: 0, deviceID: "aggregate")
        )
        let laterSave = try decodedLegacySaveMutation(
            reminder: reminder,
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "legacy-save"),
            mutationID: UUID()
        )

        #expect(throws: SyncRecordValidationError.illegalAtomicDomain(
            .init(kind: .knittingReminder, uuid: reminder.id)
        )) {
            _ = try SyncMergeEngine().merge(
                local: [aggregate], remote: [],
                pendingLocalMutations: [
                    .delete(
                        .init(kind: .knittingReminder, uuid: reminder.id),
                        mutationID: UUID()
                    ),
                    laterSave,
                ]
            )
        }
    }

    @Test func pendingLegacySaveSurvivesJournalRestartAndMigratesExactly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "legacy-reminder-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let reminder = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .changeYarn, target: 9, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let migrationStamp = stamp(revision: 0, deviceID: "legacy-journal")
        let mutationID = UUID()
        let aggregate = record(
            state: state(counterID: counterID, value: 0, counterRevision: 0),
            projectID: projectID,
            stamp: migrationStamp
        )
        let fixture = try legacySaveMutationFixture(
            reminder: reminder,
            projectID: projectID,
            stamp: migrationStamp,
            mutationID: mutationID
        )
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "mutations": [fixture.object],
        ], options: [.sortedKeys]).write(to: journalURL)

        let pending = try FileSyncMutationJournal(url: journalURL).pending()
        let migrated = try SyncMergeEngine().merge(
            local: [aggregate], remote: [], pendingLocalMutations: pending
        )

        #expect(pending == [fixture.mutation])
        #expect(migrated.records[0].counterReminderState?.reminders.map(\.id)
            == [reminder.id])
        #expect(migrated.mutationsToUpload.first?.recordID
            == .init(kind: .projectCounter, uuid: counterID))
        #expect(migrated.mutationsToUpload.first?.mutationID == mutationID)
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

    @Test func embeddedProcessedProofMergesOnFreshDeviceWithEmptyLocalLedger() throws {
        let counterID = UUID()
        let projectID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command,
            expectedCounterRevision: 0,
            expectedCounterValue: 0
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: nil,
            preparedCommand: prepared,
            effectProof: .init(counter: ProjectCounter(
                id: counterID, defaultOrdinal: 1, value: 1, mutationRevision: 1
            ))
        )
        let older = state(counterID: counterID, value: 0, counterRevision: 0)
        let newer = state(
            counterID: counterID,
            value: 1,
            counterRevision: 1,
            processedCommandIDs: [command.id],
            processedCommandProofs: [proof]
        )

        let merged = try SyncCounterReminderMergePolicy().merge(
            .init(value: older, stamp: stamp(revision: 0, deviceID: "first")),
            .init(value: newer, stamp: stamp(revision: 1, deviceID: "second")),
            context: .init()
        )

        #expect(merged.value.processedCommandIDs == [command.id])
        #expect(merged.value.processedCommandProofs == [proof])
        #expect(try JSONDecoder().decode(
            SyncCounterReminderState.self,
            from: JSONEncoder().encode(merged.value)
        ).processedCommandProofs == [proof])
    }

    @Test func recordValidationRejectsEmbeddedAcceptedProofWithWrongEffect() throws {
        let counterID = UUID()
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID.uuid, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 0, expectedCounterValue: 0
        )
        let invalidProof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: nil,
            preparedCommand: prepared,
            effectProof: .init(counter: ProjectCounter(
                id: counterID, defaultOrdinal: 1, value: 99, mutationRevision: 1
            ))
        )
        let aggregate = record(
            state: state(
                counterID: counterID,
                value: 1,
                counterRevision: 1,
                processedCommandIDs: [command.id],
                processedCommandProofs: [invalidProof]
            ),
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "device")
        )

        #expect(throws: SyncRecordValidationError.illegalAtomicDomain(aggregate.id)) {
            _ = try SyncRecordValidator().validate(aggregate)
        }
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
        ledger.record(
            command.id,
            preparedCommand: prepared,
            effectProof: .init(counter: ProjectCounter(
                id: counterID,
                defaultOrdinal: 1,
                value: 10,
                mutationRevision: 5
            )),
            at: Date(timeIntervalSince1970: 2)
        )
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

    @Test func alreadyProcessedIDCannotBypassExactOutcomeProof() {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID.uuid, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 4, expectedCounterValue: 9
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, preparedCommand: prepared, at: Date(timeIntervalSince1970: 2))
        let incompatible = record(
            state: state(
                counterID: counterID, value: 8, counterRevision: 5,
                processedCommandIDs: [command.id]
            ),
            projectID: projectID,
            stamp: stamp(revision: 6, deviceID: "incompatible")
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncMergeEngine().merge(
                local: [incompatible], remote: [], pendingLocal: [],
                counterReminderContext: .init(processedLedger: ledger)
            )
        }
    }

    @Test func rejectedLedgerMismatchCannotProveProcessedID() {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID.uuid, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let expected = PreparedWatchCommand(
            command: command, expectedCounterRevision: 3, expectedCounterValue: 4
        )
        let differentCommand = WatchCounterCommand(
            id: command.id, projectID: projectID.uuid, counterID: counterID,
            operation: .decrement, createdAt: command.createdAt
        )
        let different = PreparedWatchCommand(
            command: differentCommand, expectedCounterRevision: 3,
            expectedCounterValue: 4
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(
            command.id, rejection: .reminderMismatch,
            preparedCommand: different, at: Date(timeIntervalSince1970: 2)
        )
        let candidate = record(
            state: state(
                counterID: counterID, value: 4, counterRevision: 3,
                processedCommandIDs: [command.id]
            ),
            projectID: projectID,
            stamp: stamp(revision: 3, deviceID: "candidate")
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncMergeEngine().merge(
                local: [candidate], remote: [], pendingLocal: [],
                counterReminderContext: .init(
                    preparedCommands: [expected], processedLedger: ledger
                )
            )
        }
    }

    @Test func transientPreparedCommandCannotSubstituteForDurableProof() {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID.uuid, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 3, expectedCounterValue: 4
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(
            command.id,
            effectProof: .init(counter: ProjectCounter(
                id: counterID, defaultOrdinal: 1, value: 5, mutationRevision: 4
            )),
            at: Date(timeIntervalSince1970: 2)
        )
        let candidate = record(
            state: state(
                counterID: counterID, value: 5, counterRevision: 4,
                processedCommandIDs: [command.id]
            ),
            projectID: projectID,
            stamp: stamp(revision: 4, deviceID: "candidate")
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncMergeEngine().merge(
                local: [candidate], remote: [], pendingLocal: [],
                counterReminderContext: .init(
                    preparedCommands: [prepared], processedLedger: ledger
                )
            )
        }
    }

    @Test func acceptedLedgerWithoutEffectProofFailsEvenWhenAggregateMatches() {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID.uuid, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 3, expectedCounterValue: 4
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(
            command.id, preparedCommand: prepared,
            at: Date(timeIntervalSince1970: 2)
        )
        let coincidental = record(
            state: state(
                counterID: counterID, value: 5, counterRevision: 4,
                processedCommandIDs: [command.id]
            ),
            projectID: projectID,
            stamp: stamp(revision: 4, deviceID: "coincidental")
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncMergeEngine().merge(
                local: [coincidental], remote: [], pendingLocal: [],
                counterReminderContext: .init(processedLedger: ledger)
            )
        }
    }

    @Test func nonmatchingEffectProofCannotFallBackToCoincidentalAggregate() {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID.uuid, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 3, expectedCounterValue: 4
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(
            command.id, preparedCommand: prepared,
            effectProof: .init(counter: ProjectCounter(
                id: counterID, defaultOrdinal: 1, value: 4, mutationRevision: 4
            )),
            at: Date(timeIntervalSince1970: 2)
        )
        let coincidental = record(
            state: state(
                counterID: counterID, value: 5, counterRevision: 4,
                processedCommandIDs: [command.id]
            ),
            projectID: projectID,
            stamp: stamp(revision: 4, deviceID: "coincidental")
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncMergeEngine().merge(
                local: [coincidental], remote: [], pendingLocal: [],
                counterReminderContext: .init(processedLedger: ledger)
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
        let expectedStopped = try triggered.applying(.stop(
            observedRevision: triggered.mutationRevision
        ))
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(
            command.id,
            preparedCommand: prepared,
            effectProof: .init(
                counter: ProjectCounter(
                    id: counterID,
                    defaultOrdinal: 1,
                    value: 1,
                    mutationRevision: 4
                ),
                reminder: expectedStopped
            ),
            at: Date(timeIntervalSince1970: 3)
        )
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
        var replayLedger = ledger
        replayLedger.record(
            command.id,
            preparedCommand: prepared,
            effectProof: .init(counter: first.state.counter, reminder: first.state.reminder),
            at: Date(timeIntervalSince1970: 4)
        )
        let replay = try policy.applyingStop(
            prepared,
            to: first.state,
            processedLedger: replayLedger
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

    @Test func activeStopCannotConsumeAcceptedLedgerWithoutDurableEffectProof() throws {
        let counterID = UUID()
        let base = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let triggered = try base.applying(.trigger(through: 1))
        let occurrence = try #require(triggered.progress.pending.first)
        let command = WatchCounterCommand(
            schemaVersion: 2, id: UUID(), projectID: UUID(), counterID: counterID,
            operation: .stopReminder, reminderID: triggered.id,
            occurrenceID: occurrence.id,
            observedMutationRevision: triggered.mutationRevision,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 1, expectedCounterValue: 1,
            expectedReminderID: triggered.id, expectedOccurrenceID: occurrence.id,
            expectedReminderRevision: triggered.mutationRevision
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(
            command.id,
            preparedCommand: prepared,
            at: Date(timeIntervalSince1970: 3)
        )
        let aggregate = state(
            counterID: counterID, value: 1, counterRevision: 1,
            reminder: triggered, preparedCommand: prepared
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncCounterReminderMergePolicy().applyingStop(
                prepared, to: aggregate, processedLedger: ledger
            )
        }
    }

    @Test func equalStampLegacyAggregateAcceptsAdditiveTransferableProof() throws {
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 0, expectedCounterValue: 0
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: nil,
            preparedCommand: prepared,
            effectProof: .init(counter: ProjectCounter(
                id: counterID, defaultOrdinal: 1, value: 1, mutationRevision: 1
            ))
        )
        let legacy = state(
            counterID: counterID, value: 1, counterRevision: 1,
            processedCommandIDs: [command.id]
        )
        let upgraded = state(
            counterID: counterID, value: 1, counterRevision: 1,
            processedCommandIDs: [command.id], processedCommandProofs: [proof]
        )
        let sameStamp = stamp(revision: 1, deviceID: "same")

        let merged = try SyncCounterReminderMergePolicy().merge(
            .init(value: legacy, stamp: sameStamp),
            .init(value: upgraded, stamp: sameStamp),
            context: .init()
        )

        #expect(merged.value.processedCommandProofs == [proof])
    }

    @Test func equalStampAggregatesMonotonicallyUnionTransferredProcessedCommand() throws {
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 0, expectedCounterValue: 0
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: nil,
            preparedCommand: prepared,
            effectProof: .init(counter: ProjectCounter(
                id: counterID, defaultOrdinal: 1, value: 1, mutationRevision: 1
            ))
        )
        let withoutProcessedCommand = state(
            counterID: counterID, value: 1, counterRevision: 1
        )
        let withProcessedCommand = state(
            counterID: counterID, value: 1, counterRevision: 1,
            processedCommandIDs: [command.id], processedCommandProofs: [proof]
        )
        let sameStamp = stamp(revision: 1, deviceID: "same")

        let merged = try SyncCounterReminderMergePolicy().merge(
            .init(value: withoutProcessedCommand, stamp: sameStamp),
            .init(value: withProcessedCommand, stamp: sameStamp),
            context: .init()
        )

        #expect(merged.value.processedCommandIDs == [command.id])
        #expect(merged.value.processedCommandProofs == [proof])
    }

    @Test func embeddedRejectionProofMergesWithoutLocalLedger() throws {
        let counterID = UUID()
        let commandID = UUID()
        let command = WatchCounterCommand(
            id: commandID,
            projectID: UUID(),
            counterID: counterID,
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: commandID,
            counterID: counterID,
            rejection: .entitlementRequired,
            commandIdentity: .init(command),
            preparedCommand: nil,
            effectProof: nil
        )
        let older = state(counterID: counterID, value: 0, counterRevision: 0)
        let newer = state(
            counterID: counterID, value: 0, counterRevision: 0,
            processedCommandIDs: [commandID], processedCommandProofs: [proof]
        )

        let merged = try SyncCounterReminderMergePolicy().merge(
            .init(value: older, stamp: stamp(revision: 1, deviceID: "older")),
            .init(value: newer, stamp: stamp(revision: 2, deviceID: "newer")),
            context: .init()
        )

        #expect(merged.value.processedCommandIDs == [commandID])
        #expect(merged.value.processedCommandProofs == [proof])
    }

    @Test func orphanAndEmbeddedProofDivergenceFailsClosedGlobally() throws {
        // Production break caught: per-record validation alone permits an orphan
        // and a counter aggregate to claim different outcomes for one command ID.
        let counterID = UUID()
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID.uuid, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let embedded = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: .counterMissing,
            commandIdentity: .init(command),
            preparedCommand: nil,
            effectProof: nil,
            processingStamp: stamp(revision: 0, deviceID: "embedded-processing")
        )
        let orphan = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: .projectMissing,
            commandIdentity: .init(command),
            preparedCommand: nil,
            effectProof: nil,
            processingStamp: stamp(revision: 0, deviceID: "orphan-processing")
        )
        let aggregate = record(
            state: state(
                counterID: counterID,
                value: 0,
                counterRevision: 0,
                processedCommandIDs: [command.id],
                processedCommandProofs: [embedded]
            ),
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "aggregate")
        )
        let orphanStamp = stamp(revision: 1, deviceID: "orphan")
        let orphanRecord = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .watchCommandProof, uuid: command.id),
            createdAt: command.createdAt,
            entityRevision: orphanStamp.logicalRevision,
            payload: .init(
                fields: [:],
                atomicDomain: .init(
                    value: .orphanWatchCommandProof(
                        try SyncOrphanWatchCommandProof(proof: orphan)
                    ),
                    stamp: orphanStamp
                )
            ),
            relationships: [],
            deletedAt: .init(value: nil, stamp: orphanStamp)
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncMergeEngine().merge(
                local: [aggregate],
                remote: [orphanRecord],
                pendingLocal: []
            )
        }
    }

    @Test func freshDeviceMergeRetainsOrphanBeforeAndAfterCounterReappearance() throws {
        let counterID = UUID()
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID.uuid, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 4)
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: .counterMissing,
            commandIdentity: .init(command),
            preparedCommand: nil,
            effectProof: nil,
            processingStamp: stamp(revision: 0, deviceID: "originating-device")
        )
        let orphanStamp = stamp(revision: 1, deviceID: "publishing-device")
        let orphanRecord = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .watchCommandProof, uuid: command.id),
            createdAt: command.createdAt,
            entityRevision: orphanStamp.logicalRevision,
            payload: .init(
                fields: [:],
                atomicDomain: .init(
                    value: .orphanWatchCommandProof(
                        try SyncOrphanWatchCommandProof(proof: proof)
                    ),
                    stamp: orphanStamp
                )
            ),
            relationships: [],
            deletedAt: .init(value: nil, stamp: orphanStamp)
        )

        let fresh = try SyncMergeEngine().merge(
            local: [], remote: [orphanRecord], pendingLocal: []
        )
        #expect(fresh.records == [orphanRecord])

        let aggregate = record(
            state: state(
                counterID: counterID,
                value: 0,
                counterRevision: 0,
                processedCommandIDs: [command.id],
                processedCommandProofs: [proof]
            ),
            projectID: projectID,
            stamp: stamp(revision: 1, deviceID: "reappeared-device")
        )
        let reappeared = try SyncMergeEngine().merge(
            local: [aggregate], remote: fresh.records, pendingLocal: []
        )

        #expect(Set(reappeared.records.map(\.id)) == [aggregate.id, orphanRecord.id])
        #expect(reappeared.records.first { $0.id == aggregate.id }?
            .counterReminderState?.processedCommandProofs == [proof])
        #expect(reappeared.records.first { $0.id == orphanRecord.id } == orphanRecord)
    }

    @Test func rejectionProofWithoutCommandIdentityIsRejected() {
        #expect(throws: SyncRecordVersionError.corrupt) {
            _ = try SyncProcessedWatchCommandProof(
                id: UUID(),
                counterID: UUID(),
                rejection: .entitlementRequired,
                preparedCommand: nil,
                effectProof: nil
            )
        }
    }

    @Test func alreadyStoppedMismatchCannotAcquireProcessedIDAsNoOp() throws {
        let counterID = UUID()
        let base = try #require(KnittingReminder(
            id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let triggered = try base.applying(.trigger(through: 1))
        let occurrence = try #require(triggered.progress.pending.first)
        let stopped = try triggered.applying(.stop(
            observedRevision: triggered.mutationRevision
        ))
        let mismatchedOccurrenceID = UUID()
        let command = WatchCounterCommand(
            schemaVersion: 2, id: UUID(), projectID: UUID(), counterID: counterID,
            operation: .stopReminder, reminderID: stopped.id,
            occurrenceID: mismatchedOccurrenceID,
            observedMutationRevision: triggered.mutationRevision + 9,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let prepared = PreparedWatchCommand(
            command: command, expectedCounterRevision: 1, expectedCounterValue: 1,
            expectedReminderID: stopped.id, expectedOccurrenceID: mismatchedOccurrenceID,
            expectedReminderRevision: triggered.mutationRevision + 9
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, preparedCommand: prepared, at: Date(timeIntervalSince1970: 3))
        let aggregate = state(
            counterID: counterID, value: 1, counterRevision: 1,
            reminder: stopped, preparedCommand: prepared
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            _ = try SyncCounterReminderMergePolicy().applyingStop(
                prepared, to: aggregate, processedLedger: ledger
            )
        }
        #expect(!aggregate.processedCommandIDs.contains(command.id))
        #expect(!stopped.progress.pending.contains { $0.id == occurrence.id })
    }
}

private func state(
    counterID: UUID,
    value: Int,
    counterRevision: UInt64,
    reminder: KnittingReminder? = nil,
    preparedCommand: PreparedWatchCommand? = nil,
    processedCommandIDs: Set<UUID> = [],
    processedCommandProofs: [SyncProcessedWatchCommandProof] = []
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
        processedCommandProofs: processedCommandProofs,
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

private func legacyReminderRecord(
    reminder: KnittingReminder,
    stamp: SyncMutationStamp,
    deletedAt: SyncFieldVersion<Date?>? = nil
) -> SyncRecord {
    SyncRecord(
        schemaVersion: 1,
        id: .init(kind: .knittingReminder, uuid: reminder.id),
        createdAt: reminder.createdAt,
        entityRevision: reminder.mutationRevision,
        payload: .init(
            fields: [:],
            atomicDomain: .init(value: .knittingReminder(reminder), stamp: stamp)
        ),
        relationships: [.init(
            role: "counter",
            target: .init(kind: .projectCounter, uuid: reminder.counterID)
        )],
        deletedAt: deletedAt ?? .init(value: nil, stamp: stamp)
    )
}

private func decodedLegacySaveMutation(
    reminder: KnittingReminder,
    projectID: SyncEntityID,
    stamp: SyncMutationStamp,
    mutationID: UUID
) throws -> SyncMutation {
    try legacySaveMutationFixture(
        reminder: reminder,
        projectID: projectID,
        stamp: stamp,
        mutationID: mutationID
    ).mutation
}

private func legacySaveMutationFixture(
    reminder: KnittingReminder,
    projectID: SyncEntityID,
    stamp: SyncMutationStamp,
    mutationID: UUID
) throws -> (mutation: SyncMutation, object: [String: Any]) {
    let canonicalRecord = record(
        state: state(
            counterID: reminder.counterID,
            value: 0,
            counterRevision: reminder.mutationRevision
        ),
        projectID: projectID,
        stamp: stamp
    )
    let canonicalMutation = try SyncMutation.save(
        recordVersion: SyncRecordVersion(record: canonicalRecord),
        mutationID: mutationID
    )
    var mutationObject = try #require(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(canonicalMutation)
    ) as? [String: Any])
    var saveCase = try #require(mutationObject["save"] as? [String: Any])
    var saveValue = try #require(saveCase["_0"] as? [String: Any])
    var recordVersion = try #require(saveValue["recordVersion"] as? [String: Any])
    var legacyRecordObject = try #require(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(canonicalRecord)
    ) as? [String: Any])
    legacyRecordObject["id"] = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(SyncEntityID(
            kind: .knittingReminder,
            uuid: reminder.id
        ))
    )
    legacyRecordObject["entityRevision"] = reminder.mutationRevision
    legacyRecordObject["relationships"] = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode([
            SyncRelationship(role: "project", target: projectID),
            SyncRelationship(
                role: "counter",
                target: .init(kind: .projectCounter, uuid: reminder.counterID)
            ),
        ])
    )
    var payload = try #require(legacyRecordObject["payload"] as? [String: Any])
    var atomic = try #require(payload["atomicDomain"] as? [String: Any])
    let reminderObject = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(reminder)
    )
    atomic["value"] = ["knittingReminder": ["_0": reminderObject]]
    payload["atomicDomain"] = atomic
    legacyRecordObject["payload"] = payload
    let identityBytes = try JSONSerialization.data(
        withJSONObject: legacyRecordObject,
        options: [.sortedKeys]
    )
    recordVersion["versionID"] = uuidFromDigest(
        Data(SHA256.hash(data: identityBytes))
    ).uuidString
    recordVersion["record"] = legacyRecordObject
    saveValue["recordVersion"] = recordVersion
    saveCase["_0"] = saveValue
    mutationObject["save"] = saveCase
    let mutation = try JSONDecoder().decode(
        SyncMutation.self,
        from: JSONSerialization.data(withJSONObject: mutationObject)
    )
    return (mutation, mutationObject)
}

private func uuidFromDigest(_ digest: Data) -> UUID {
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
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
