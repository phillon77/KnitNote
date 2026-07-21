import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchSyncModelsTests {
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
            generatedAt: Date(timeIntervalSince1970: 101), projects: [project]
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
}
