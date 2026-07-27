import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct TrialRecordTests {
    @Test func recordUsesExactlySevenDays() {
        let now = Date(timeIntervalSince1970: 1_000)

        let record = TrialRecord(startedAt: now)

        #expect(record.expiresAt == Date(timeIntervalSince1970: 605_800))
    }

    @Test func existingRecordIsNeverRestarted() throws {
        let existing = TrialRecord(startedAt: Date(timeIntervalSince1970: 1_000))
        let store = InMemoryTrialStore(record: existing)

        let result = try store.startIfNeeded(now: Date(timeIntervalSince1970: 9_000))

        #expect(result == existing)
    }
}

private struct InMemoryTrialStore: TrialStore {
    let record: TrialRecord?

    func load() throws -> TrialRecord? {
        record
    }

    func startIfNeeded(now: Date) throws -> TrialRecord {
        record ?? TrialRecord(startedAt: now)
    }
}
