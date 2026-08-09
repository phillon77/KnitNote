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

    @Test func repeatingReminderCapsPendingOccurrencesAtItsLimit() throws {
        var counter = ProjectCounter(defaultOrdinal: 1, value: 4)
        counter.configureReminder(.repeating(interval: 5, limit: 2, message: "Turn"))

        let applied = counter.applyValue(20)
        let due = try #require(applied?.pendingReminder)

        #expect(due.occurrenceCount == 2)
        #expect(due.firstTarget == 9)
        #expect(due.lastTarget == 14)
        #expect(counter.reminder?.nextTarget == nil)
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
}
