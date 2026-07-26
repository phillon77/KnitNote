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

    @Test func everyCreatedPatternEntryPointSchedulesTheSameOneShotReminder() throws {
        let suiteName = "BackupHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let patternIDs = [UUID(), UUID(), UUID()]
        var coordinator = PatternBackupReminderCoordinator(
            history: BackupHistory(defaults: defaults)
        )

        coordinator.accept(.created(patternID: patternIDs[0]))
        coordinator.accept([.created(patternID: patternIDs[1])])
        coordinator.accept(.created(patternID: patternIDs[2]))

        #expect(coordinator.isPresented)
        #expect(!coordinator.isShowingBackupSettings)

        coordinator.dismiss(openBackupSettings: false)
        #expect(!coordinator.isPresented)
        #expect(BackupHistory(defaults: defaults).hasShownPatternReminder)

        var relaunched = PatternBackupReminderCoordinator(
            history: BackupHistory(defaults: defaults)
        )
        relaunched.accept(.created(patternID: UUID()))
        #expect(!relaunched.isPresented)
    }

    @Test func reusedPendingCancelledAndFailedImportsNeverScheduleTheReminder() throws {
        let suiteName = "BackupHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var coordinator = PatternBackupReminderCoordinator(
            history: BackupHistory(defaults: defaults)
        )

        coordinator.accept(.existing(patternID: UUID()))
        coordinator.accept(.needsSelection(
            itemID: UUID(),
            candidatePatternIDs: [UUID(), UUID()]
        ))
        coordinator.accept([])

        #expect(!coordinator.isPresented)
        #expect(!BackupHistory(defaults: defaults).hasShownPatternReminder)
    }

    @Test func dismissingToSettingsPersistsBeforeOpeningAndCanCloseTheRoute() throws {
        let suiteName = "BackupHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var coordinator = PatternBackupReminderCoordinator(
            history: BackupHistory(defaults: defaults)
        )
        coordinator.accept(.created(patternID: UUID()))

        coordinator.dismiss(openBackupSettings: true)

        #expect(!coordinator.isPresented)
        #expect(coordinator.isShowingBackupSettings)
        #expect(BackupHistory(defaults: defaults).hasShownPatternReminder)

        coordinator.closeBackupSettings()
        #expect(!coordinator.isShowingBackupSettings)
    }
}
