import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchSyncModelsTests {
    @Test func schemaFourProjectsCarryStrictReminderOccurrences() throws {
        let counterID = UUID()
        let reminderID = UUID()
        let occurrence = WatchKnittingReminderOccurrenceSnapshot(
            id: UUID(), reminderID: reminderID, kind: .changeYarn,
            text: "原樣文字", originalTarget: 12, displayAt: 12,
            phase: .initial, awaitsNextUpwardChange: false
        )
        let reminder = try WatchKnittingReminderSnapshot(
            id: reminderID, counterID: counterID, kind: .changeYarn,
            text: "原樣文字", rule: .oneTime(target: 12), state: .active,
            mutationRevision: 7, createdAt: Date(timeIntervalSince1970: 1),
            scheduledCount: 1, completedCount: 0, skippedCount: 0,
            nextTarget: nil, nextOccurrenceIndex: 2, lastObservedCounterValue: 12,
            pending: [occurrence]
        )
        let counters = (0..<6).map { ordinal in
            WatchCounterSnapshot(id: ordinal == 0 ? counterID : UUID(), name: "C", value: 12)
        }
        let project = try WatchProjectSnapshot(
            id: UUID(), name: "Project", isCompleted: false, updatedAt: .now,
            counters: counters, selectedCounterID: counterID, knittingReminders: [reminder]
        )
        let snapshot = WatchSyncSnapshot(
            generatedAt: .now,
            entitlement: .init(kind: .permanentlyUnlocked, expiresAt: nil, generatedAt: .now),
            projects: [project]
        )

        let decoded = try WatchSyncCodec.decode(WatchSyncSnapshot.self, from: WatchSyncCodec.encode(snapshot))

        #expect(WatchSyncSnapshot.currentSchemaVersion == 4)
        #expect(decoded.projects[0].knittingReminders[0].pending[0].text == "原樣文字")
        #expect(decoded.projects[0].knittingReminders[0].mutationRevision == 7)
    }

    @Test func schemaThreeSnapshotAndSchemaTwoCommandDecodeForRecoveryOnly() throws {
        let snapshot = try WatchSyncCodec.decode(WatchSyncSnapshot.self, from: Data(#"""
        {"schemaVersion":3,"generatedAt":0,"entitlement":{"kind":"permanentlyUnlocked","generatedAt":0},"projects":[]}
        """#.utf8))
        let command = try WatchSyncCodec.decode(WatchCounterCommand.self, from: Data(#"""
        {"schemaVersion":2,"id":"00000000-0000-0000-0000-000000000001","projectID":"00000000-0000-0000-0000-000000000002","counterID":"00000000-0000-0000-0000-000000000003","operation":"increment","createdAt":0}
        """#.utf8))

        #expect(snapshot.schemaVersion == 3)
        #expect(command.schemaVersion == 2)
        #expect(WatchCounterCommand.currentSchemaVersion == 3)
    }

    @Test func reminderCommandsRequireOneExactActionPayload() throws {
        let payload = WatchReminderActionPayload(
            reminderID: UUID(), occurrenceID: UUID(), observedRevision: 3
        )
        let command = WatchCounterCommand(
            projectID: UUID(), counterID: UUID(), operation: .deferReminderOnce,
            reminderPayload: payload
        )

        #expect(command.hasValidPayload)
        #expect(try WatchSyncCodec.decode(WatchCounterCommand.self, from: WatchSyncCodec.encode(command)) == command)
        #expect(!WatchCounterCommand(
            projectID: UUID(), counterID: UUID(), operation: .skipReminder
        ).hasValidPayload)
    }

    @Test func newSnapshotRoundTripPreservesSelectedLanguage() throws {
        let snapshot = WatchSyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: 101),
            entitlement: WatchEntitlementSnapshot(
                kind: .permanentlyUnlocked,
                expiresAt: nil,
                generatedAt: Date(timeIntervalSince1970: 101)
            ),
            projects: [],
            languageCode: "ja"
        )

        let decoded = try WatchSyncCodec.decode(
            WatchSyncSnapshot.self,
            from: WatchSyncCodec.encode(snapshot)
        )

        #expect(decoded.schemaVersion == 4)
        #expect(decoded.languageCode == "ja")
    }

    @Test func currentSnapshotWithoutLanguageStillDecodes() throws {
        let currentSnapshotJSON = Data(#"""
        {
          "schemaVersion": 3,
          "generatedAt": 101000,
          "entitlement": {
            "kind": "permanentlyUnlocked",
            "generatedAt": 101000
          },
          "projects": []
        }
        """#.utf8)

        let decoded = try WatchSyncCodec.decode(
            WatchSyncSnapshot.self,
            from: currentSnapshotJSON
        )

        #expect(decoded.schemaVersion == 3)
        #expect(decoded.languageCode == nil)
    }

    @Test func priorSnapshotSchemaIsRejectedAfterReminderProtocolUpgrade() {
        let data = Data(#"{"schemaVersion":2,"generatedAt":0,"entitlement":{"kind":"permanentlyUnlocked","generatedAt":0},"projects":[]}"#.utf8)

        #expect(throws: WatchSyncValidationError.unsupportedSchema) {
            _ = try WatchSyncCodec.decode(WatchSyncSnapshot.self, from: data)
        }
    }

    @Test func snapshotBuilderCarriesSelectedLanguage() throws {
        let snapshot = try WatchSnapshotBuilder.make(
            projects: [],
            entitlement: .permanentlyUnlocked,
            locale: Locale(identifier: "fr"),
            languageCode: "fr",
            generatedAt: Date(timeIntervalSince1970: 101)
        )

        #expect(snapshot.languageCode == "fr")
    }

    @Test func snapshotRoundTripsSixCounters() throws {
        let counters = (1...6).map {
            WatchCounterSnapshot(id: UUID(), name: "Counter \($0)", value: $0)
        }
        let project = try WatchProjectSnapshot(
            id: UUID(), name: "Sweater", isCompleted: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            counters: counters, selectedCounterID: counters[2].id
        )
        let value = WatchSyncSnapshot(
            schemaVersion: WatchSyncSnapshot.currentSchemaVersion,
            generatedAt: Date(timeIntervalSince1970: 101),
            entitlement: WatchEntitlementSnapshot(
                kind: .permanentlyUnlocked,
                expiresAt: nil,
                generatedAt: Date(timeIntervalSince1970: 101)
            ),
            projects: [project]
        )
        let decoded = try WatchSyncCodec.decode(
            WatchSyncSnapshot.self,
            from: WatchSyncCodec.encode(value)
        )
        #expect(decoded == value)
    }

    @Test func projectRejectsAnythingOtherThanSixUniqueCounters() {
        #expect(throws: WatchSyncValidationError.invalidCounterCount) {
            _ = try WatchProjectSnapshot(
                id: UUID(), name: "Bad", isCompleted: false, updatedAt: .now,
                counters: [WatchCounterSnapshot(id: UUID(), name: "Only", value: 0)],
                selectedCounterID: UUID()
            )
        }
    }

    @Test func projectRejectsDuplicateCounterIDs() {
        let counterID = UUID()
        let counters = (1...6).map {
            WatchCounterSnapshot(id: counterID, name: "Counter \($0)", value: $0)
        }

        #expect(throws: WatchSyncValidationError.duplicateCounterID) {
            _ = try WatchProjectSnapshot(
                id: UUID(), name: "Bad", isCompleted: false, updatedAt: .now,
                counters: counters, selectedCounterID: counterID
            )
        }
    }

    @Test func projectRejectsSelectedCounterOutsideItsCounters() {
        let counters = (1...6).map {
            WatchCounterSnapshot(id: UUID(), name: "Counter \($0)", value: $0)
        }

        #expect(throws: WatchSyncValidationError.invalidSelectedCounter) {
            _ = try WatchProjectSnapshot(
                id: UUID(), name: "Bad", isCompleted: false, updatedAt: .now,
                counters: counters, selectedCounterID: UUID()
            )
        }
    }

    @Test func decodedProjectRejectsMalformedCounterArray() {
        let data = Data(#"""
        {"id":"00000000-0000-0000-0000-000000000001","name":"Bad","isCompleted":false,"updatedAt":0,"counters":[{"id":"00000000-0000-0000-0000-000000000002","name":"Only","value":0}],"selectedCounterID":"00000000-0000-0000-0000-000000000002"}
        """#.utf8)

        #expect(throws: WatchSyncValidationError.invalidCounterCount) {
            _ = try WatchSyncCodec.decode(WatchProjectSnapshot.self, from: data)
        }
    }

    @Test func reminderTargetBehindCounterDecodesAsAbsentWithoutLosingCounter() throws {
        let data = Data(#"""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "name":"Body",
          "value":5,
          "reminder":{
            "id":"00000000-0000-0000-0000-000000000002",
            "nextTarget":3,
            "message":"Turn",
            "isActive":true
          }
        }
        """#.utf8)

        let counter = try WatchSyncCodec.decode(WatchCounterSnapshot.self, from: data)

        #expect(counter.value == 5)
        #expect(counter.reminder?.nextTarget == 3)
    }

    @Test func unsupportedSchemaIsRejected() throws {
        let data = Data(#"{"schemaVersion":99,"generatedAt":0,"projects":[]}"#.utf8)
        #expect(throws: WatchSyncValidationError.unsupportedSchema) {
            _ = try WatchSyncCodec.decode(WatchSyncSnapshot.self, from: data)
        }
    }

    @Test func commandCarriesStableIdentityAndOperation() throws {
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: UUID(),
            operation: .decrement, createdAt: Date(timeIntervalSince1970: 42)
        )
        #expect(try WatchSyncCodec.decode(
            WatchCounterCommand.self,
            from: WatchSyncCodec.encode(command)
        ) == command)
    }

    @Test func reminderSnapshotAndCommandPayloadRoundTrip() throws {
        let counter = WatchCounterSnapshot(id: UUID(), name: "Body", value: 20)
        let reminderID = UUID()
        let payload = WatchReminderActionPayload(
            reminderID: reminderID, occurrenceID: UUID(), observedRevision: 2
        )
        let command = WatchCounterCommand(
            projectID: UUID(),
            counterID: counter.id,
            operation: .completeReminder,
            reminderPayload: payload,
            createdAt: Date(timeIntervalSince1970: 42)
        )

        #expect(try WatchSyncCodec.decode(
            WatchCounterSnapshot.self,
            from: WatchSyncCodec.encode(counter)
        ) == counter)
        #expect(try WatchSyncCodec.decode(
            WatchCounterCommand.self,
            from: WatchSyncCodec.encode(command)
        ) == command)
    }

    @Test func commandDecoderRejectsReminderPayloadForCounterValueOperation() throws {
        let command = WatchCounterCommand(
            projectID: UUID(),
            counterID: UUID(),
            operation: .increment,
            reminderID: UUID(),
            observedPendingCount: 1
        )

        #expect(throws: WatchSyncValidationError.invalidCommandPayload) {
            _ = try WatchSyncCodec.decode(
                WatchCounterCommand.self,
                from: WatchSyncCodec.encode(command)
            )
        }
    }

    @Test(arguments: [0, -1])
    func completeReminderDecoderRequiresPositiveObservedCount(_ observedCount: Int) throws {
        let command = WatchCounterCommand(
            projectID: UUID(),
            counterID: UUID(),
            operation: .completeReminder,
            reminderID: UUID(),
            observedPendingCount: observedCount
        )

        #expect(throws: WatchSyncValidationError.invalidCommandPayload) {
            _ = try WatchSyncCodec.decode(
                WatchCounterCommand.self,
                from: WatchSyncCodec.encode(command)
            )
        }
    }

    @Test func stopReminderDecoderRequiresAnIDAndNoObservedCount() throws {
        let missingID = WatchCounterCommand(
            projectID: UUID(),
            counterID: UUID(),
            operation: .stopReminder
        )
        let unexpectedCount = WatchCounterCommand(
            projectID: UUID(),
            counterID: UUID(),
            operation: .stopReminder,
            reminderID: UUID(),
            observedPendingCount: 1
        )

        for command in [missingID, unexpectedCount] {
            #expect(throws: WatchSyncValidationError.invalidCommandPayload) {
                _ = try WatchSyncCodec.decode(
                    WatchCounterCommand.self,
                    from: WatchSyncCodec.encode(command)
                )
            }
        }
    }

    @Test func directCommandDecodingRejectsUnsupportedSchema() {
        let data = Data(#"""
        {"schemaVersion":99,"id":"00000000-0000-0000-0000-000000000001","projectID":"00000000-0000-0000-0000-000000000002","counterID":"00000000-0000-0000-0000-000000000003","operation":"increment","createdAt":0}
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        #expect(throws: WatchSyncValidationError.unsupportedSchema) {
            _ = try decoder.decode(WatchCounterCommand.self, from: data)
        }
    }

    @Test func acknowledgementRejectsNestedUnsupportedSnapshotSchema() {
        let data = Data(#"""
        {"commandID":"00000000-0000-0000-0000-000000000001","rejection":null,"snapshot":{"schemaVersion":99,"generatedAt":0,"projects":[]}}
        """#.utf8)

        #expect(throws: WatchSyncValidationError.unsupportedSchema) {
            _ = try WatchSyncCodec.decode(WatchCommandAcknowledgement.self, from: data)
        }
    }
}
