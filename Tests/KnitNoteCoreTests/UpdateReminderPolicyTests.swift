import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct UpdateReminderPolicyTests {
    @Test func presentsOnlyForNewerVersionsAfterTheApprovedSnoozeRules() throws {
        let installed = try #require(AppVersion("1.5.1"))
        let v152 = try #require(AppVersion("1.5.2"))
        let v153 = try #require(AppVersion("1.5.3"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(UpdateReminderPolicy.shouldPresent(installed: installed, available: v152, dismissal: nil, now: now))
        #expect(!UpdateReminderPolicy.shouldPresent(installed: installed, available: installed, dismissal: nil, now: now))
        #expect(!UpdateReminderPolicy.shouldPresent(installed: v152, available: installed, dismissal: nil, now: now))

        let dismissal = UpdateReminderDismissal(version: v152, dismissedAt: now)
        #expect(!UpdateReminderPolicy.shouldPresent(installed: installed, available: v152, dismissal: dismissal, now: now.addingTimeInterval(7 * 86_400 - 1)))
        #expect(UpdateReminderPolicy.shouldPresent(installed: installed, available: v152, dismissal: dismissal, now: now.addingTimeInterval(7 * 86_400)))
        #expect(UpdateReminderPolicy.shouldPresent(installed: installed, available: v153, dismissal: dismissal, now: now.addingTimeInterval(1)))
    }

    @Test func emptyHistoryHasNoDismissal() throws {
        let suiteName = "UpdateReminderPolicyTests.empty.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(UpdateReminderHistory(defaults: defaults).dismissal == nil)
    }

    @Test func recordingLaterPersistsTheCanonicalVersionAndTimestamp() throws {
        let suiteName = "UpdateReminderPolicyTests.record.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let version = try #require(AppVersion("1.5.2"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let history = UpdateReminderHistory(defaults: defaults)
        history.recordLater(version: version, at: date)

        #expect(defaults.string(forKey: "updateReminder.dismissedVersion") == "1.5.2")
        #expect(defaults.object(forKey: "updateReminder.dismissedAt") as? Double == 1_800_000_000)
        #expect(UpdateReminderHistory(defaults: defaults).dismissal == UpdateReminderDismissal(version: version, dismissedAt: date))
    }

    @Test func corruptStoredVersionOrMissingTimestampIsCleared() throws {
        let suiteName = "UpdateReminderPolicyTests.corrupt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970

        defaults.set("1.5-beta", forKey: "updateReminder.dismissedVersion")
        defaults.set(timestamp, forKey: "updateReminder.dismissedAt")
        #expect(UpdateReminderHistory(defaults: defaults).dismissal == nil)
        #expect(defaults.object(forKey: "updateReminder.dismissedVersion") == nil)
        #expect(defaults.object(forKey: "updateReminder.dismissedAt") == nil)

        defaults.set("1.5.2", forKey: "updateReminder.dismissedVersion")
        #expect(UpdateReminderHistory(defaults: defaults).dismissal == nil)
        #expect(defaults.object(forKey: "updateReminder.dismissedVersion") == nil)
        #expect(defaults.object(forKey: "updateReminder.dismissedAt") == nil)

        defaults.set(["unexpected"], forKey: "updateReminder.dismissedVersion")
        defaults.set(["unexpected"], forKey: "updateReminder.dismissedAt")
        #expect(UpdateReminderHistory(defaults: defaults).dismissal == nil)
        #expect(defaults.object(forKey: "updateReminder.dismissedVersion") == nil)
        #expect(defaults.object(forKey: "updateReminder.dismissedAt") == nil)
    }

    @Test func constructingAndReadingAnEmptyHistoryDoesNotWriteDefaults() throws {
        let suiteName = "UpdateReminderPolicyTests.noWrites.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = UpdateReminderHistory(defaults: defaults)
        _ = history.dismissal

        #expect(defaults.persistentDomain(forName: suiteName) == nil)
    }
}
