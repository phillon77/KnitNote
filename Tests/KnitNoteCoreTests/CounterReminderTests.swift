import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct CounterReminderTests {
    @Test func repeatingReminderCombinesEveryCrossedTarget() throws {
        var counter = ProjectCounter(defaultOrdinal: 1, value: 8)
        counter.configureReminder(.repeating(interval: 10, limit: nil, message: nil))

        let applied = counter.applyValue(35)
        let outcome = try #require(applied)

        #expect(outcome.oldValue == 8)
        #expect(outcome.newValue == 35)
        #expect(outcome.pendingReminder?.occurrenceCount == 2)
        #expect(outcome.pendingReminder?.firstTarget == 18)
        #expect(outcome.pendingReminder?.lastTarget == 28)
    }

    @Test func decrementAndResetDoNotRewindAcknowledgedProgress() throws {
        var counter = ProjectCounter(defaultOrdinal: 1, value: 0)
        counter.configureReminder(.repeating(interval: 10, limit: nil, message: nil))
        let applied = counter.applyValue(10)
        let due = try #require(applied?.pendingReminder)
        let didComplete = counter.completePendingReminder(id: due.reminderID, observedCount: 1)
        #expect(didComplete)

        _ = counter.applyValue(0)

        #expect(counter.reminder?.nextTarget == 20)
        #expect(counter.applyValue(10)?.pendingReminder == nil)
    }

    @Test func finiteReminderDeactivatesAfterCompletionAtItsFinalExactTarget() throws {
        var counter = ProjectCounter(defaultOrdinal: 1, value: 4)
        counter.configureReminder(.repeating(interval: 5, limit: 2, message: "Turn"))

        let applied = counter.applyValue(14)
        let due = try #require(applied?.pendingReminder)

        #expect(due.occurrenceCount == 2)
        #expect(due.firstTarget == 9)
        #expect(due.lastTarget == 14)
        #expect(counter.reminder?.nextTarget == nil)
        let didComplete = counter.completePendingReminder(id: due.reminderID, observedCount: 2)
        #expect(didComplete)
        #expect(counter.reminder?.isActive == false)
    }

    @Test func completionRequiresMatchingReminderID() throws {
        var counter = ProjectCounter(defaultOrdinal: 1)
        counter.configureReminder(.oneTime(target: 2, message: nil))
        let applied = counter.applyValue(2)
        let due = try #require(applied?.pendingReminder)

        let didCompleteWithWrongID = counter.completePendingReminder(id: UUID(), observedCount: 1)
        #expect(!didCompleteWithWrongID)
        #expect(counter.reminder?.pending == due)
        let didComplete = counter.completePendingReminder(id: due.reminderID, observedCount: 1)
        #expect(didComplete)
        #expect(counter.reminder?.pending == nil)
        #expect(counter.reminder?.isActive == false)
    }

    @Test func stoppedReminderSurvivesCodableAsInactive() throws {
        var counter = ProjectCounter(defaultOrdinal: 1)
        counter.configureReminder(.repeating(interval: 10, limit: nil, message: nil))
        let reminderID = try #require(counter.reminder?.id)
        let didStop = counter.stopReminder(id: reminderID)
        #expect(didStop)

        let decoded = try JSONDecoder().decode(
            ProjectCounter.self,
            from: JSONEncoder().encode(counter)
        )

        #expect(decoded.reminder?.id == reminderID)
        #expect(decoded.reminder?.isActive == false)
    }

    @Test func staleObservedCountDoesNotAcknowledgePendingReminder() throws {
        var counter = ProjectCounter(defaultOrdinal: 1)
        counter.configureReminder(.repeating(interval: 10, limit: nil, message: nil))
        let applied = counter.applyValue(20)
        let due = try #require(applied?.pendingReminder)

        let didComplete = counter.completePendingReminder(id: due.reminderID, observedCount: 1)

        #expect(!didComplete)
        #expect(counter.reminder?.pending == due)
        #expect(counter.reminder?.acknowledgedCount == 0)
    }

    @Test func staleStopIDLeavesReminderActive() throws {
        var counter = ProjectCounter(defaultOrdinal: 1)
        counter.configureReminder(.repeating(interval: 10, limit: nil, message: nil))
        let reminderID = try #require(counter.reminder?.id)

        let didStop = counter.stopReminder(id: UUID())

        #expect(!didStop)
        #expect(counter.reminder?.id == reminderID)
        #expect(counter.reminder?.isActive == true)
    }

    @Test func separateUpwardMutationsAccumulateOnePendingReminder() throws {
        var counter = ProjectCounter(defaultOrdinal: 1)
        counter.configureReminder(.repeating(interval: 10, limit: nil, message: nil))
        let firstApplied = counter.applyValue(10)
        let first = try #require(firstApplied?.pendingReminder)
        let combinedApplied = counter.applyValue(30)
        let combined = try #require(combinedApplied?.pendingReminder)

        #expect(combined.reminderID == first.reminderID)
        #expect(combined.occurrenceCount == 3)
        #expect(combined.firstTarget == 10)
        #expect(combined.lastTarget == 30)
    }

    @Test func invalidReminderDraftDoesNotInstallAReminder() {
        var counter = ProjectCounter(defaultOrdinal: 1, value: 3)
        counter.configureReminder(.repeating(interval: 0, limit: nil, message: nil))

        #expect(counter.reminder == nil)
    }

    @Test func largeUnlimitedJumpNearIntMaxProducesBoundedCrossingOutcome() throws {
        var counter = ProjectCounter(defaultOrdinal: 1)
        counter.configureReminder(.repeating(interval: 1, limit: nil, message: nil))

        let applied = counter.applyValue(.max)
        let due = try #require(applied?.pendingReminder)

        #expect(due.occurrenceCount == .max)
        #expect(due.firstTarget == 1)
        #expect(due.lastTarget == .max)
        #expect(counter.reminder?.nextTarget == nil)
    }
}
