import Foundation
import Testing

@Suite struct CounterReminderViewContractTests {
    @Test func managerDoesNotKeepTheLegacyReminderCreationFlow() throws {
        let source = try sourceFile("KnitNote/Projects/CounterManagerView.swift")

        #expect(!source.contains("CounterReminderEditor("))
        #expect(!source.contains("CounterReminderDraft"))
        #expect(!source.contains("CounterReminderEdit"))
    }

    @Test func legacyReminderCardIsRemovedAfterSharedQueueMigration() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent("KnitNote/Patterns/CounterReminderCard.swift").path
        ))
    }

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }
}
