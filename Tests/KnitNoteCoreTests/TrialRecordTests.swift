import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct TrialRecordTests {
    @Test func recordUsesExactlySevenDays() {
        let now = Date(timeIntervalSince1970: 1_000)

        let record = TrialRecord(startedAt: now)

        #expect(record.expiresAt == Date(timeIntervalSince1970: 605_800))
    }

}
