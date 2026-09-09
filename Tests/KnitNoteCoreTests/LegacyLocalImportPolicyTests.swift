import Testing
@testable import KnitNoteCore

@Suite struct LegacyLocalImportPolicyTests {
    @Test func sourceTable() {
        let rows: [(LegacyLocalImportSource, LegacyLocalImportDecision)] = [
            (.availableLocalHistoryUnknown, .requiresConfirmation),
            (.provenNeverBound, .useExistingSourceFlow),
            (.currentAccount, .useExistingAccountRecovery),
            (.foreignAccount, .blocked),
            (.accountUnknown, .blocked),
            (.unverifiedRecovery, .blocked),
            (.invalidContent, .blocked),
            (.unresolvedWatchState, .blocked)
        ]
        for (source, expected) in rows {
            #expect(LegacyLocalImportPolicy.decision(for: source) == expected)
        }
    }
}
