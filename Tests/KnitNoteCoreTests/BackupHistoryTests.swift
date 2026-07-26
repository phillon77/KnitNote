import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct BackupHistoryTests {
    @Test func successfulExportPersistsItsCompletionDate() throws {
        let suiteName = "BackupHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let completedAt = Date(timeIntervalSince1970: 200)

        var history = BackupHistory(defaults: defaults)
        history.recordExportResult(.success, at: completedAt)

        let reloaded = BackupHistory(defaults: defaults)
        #expect(reloaded.lastSuccessfulExportAt == completedAt)
    }

    @Test func cancelledOrFailedExportPreservesThePreviousSuccessfulDate() throws {
        let suiteName = "BackupHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previousSuccess = Date(timeIntervalSince1970: 100)
        var history = BackupHistory(defaults: defaults)
        history.recordExportResult(.success, at: previousSuccess)

        history.recordExportResult(.cancelled, at: Date(timeIntervalSince1970: 200))
        history.recordExportResult(.failure, at: Date(timeIntervalSince1970: 300))

        #expect(history.lastSuccessfulExportAt == previousSuccess)
    }

    @Test func dismissingPatternReminderPersistsThatItWasShown() throws {
        let suiteName = "BackupHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var history = BackupHistory(defaults: defaults)

        #expect(!history.hasShownPatternReminder)
        history.markPatternReminderShown()

        let reloaded = BackupHistory(defaults: defaults)
        #expect(reloaded.hasShownPatternReminder)
    }
}
