import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnittingReminderTests {
    @Test func mainCounterSupportsMultipleSingleAndRepeatingRules() throws {
        let counterID = UUID()
        let change = try #require(KnittingReminder(
            counterID: counterID,
            draft: .oneTime(kind: .changeYarn, target: 20, text: "米白色"),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let increase = try #require(KnittingReminder(
            counterID: counterID,
            draft: .repeating(kind: .increase, firstTarget: 10, interval: 4, limit: 6, text: nil),
            createdAt: Date(timeIntervalSince1970: 2)
        ))

        let result = KnittingReminderEvaluator.evaluate(
            oldValue: 9,
            newValue: 20,
            reminders: [change, increase]
        )

        #expect(result.pending.map(\.originalTarget) == [10, 14, 18, 20])
        #expect(result.pending.last?.kind == .changeYarn)
    }

    @Test func invalidTargetsIntervalsAndLimitsAreRejected() {
        let id = UUID()
        #expect(KnittingReminder(counterID: id, draft: .oneTime(kind: .custom, target: -1, text: "x"), createdAt: .now) == nil)
        #expect(KnittingReminder(counterID: id, draft: .repeating(kind: .cable, firstTarget: 8, interval: 0, limit: nil, text: nil), createdAt: .now) == nil)
        #expect(KnittingReminder(counterID: id, draft: .repeating(kind: .cable, firstTarget: 8, interval: 4, limit: 0, text: nil), createdAt: .now) == nil)
    }

    @Test func deferredOccurrenceReturnsOnceOnTheNextUpwardRow() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .measure, target: 20, text: nil),
            createdAt: .now
        ))
        reminder = try reminder.applying(.trigger(through: 20))
        let occurrence = try #require(reminder.progress.pending.first)
        reminder = try reminder.applying(.deferOnce(occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision))

        #expect(reminder.visibleOccurrences(at: 20).isEmpty)
        #expect(reminder.visibleOccurrences(at: 21).first?.phase == .deferredOnce)
        #expect(throws: KnittingReminderMutationError.alreadyDeferred) {
            try reminder.applying(.deferOnce(occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision))
        }
    }

    @Test func skipAndResetLatestKeepCumulativeProgressBounded() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .custom, target: 8, text: "finish edge"),
            createdAt: .now
        ))
        reminder = try reminder.applying(.trigger(through: 8))
        let occurrence = try #require(reminder.progress.pending.first)
        reminder = try reminder.applying(.skip(occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision))

        #expect(reminder.state == .completed)
        #expect(reminder.progress.pending.isEmpty)
        #expect(reminder.progress.scheduledCount == 1)
        #expect(reminder.progress.completedCount == 0)
        #expect(reminder.progress.skippedCount == 1)
        #expect(reminder.progress.latestHandled?.originalTarget == 8)

        reminder = try reminder.applying(.resetLatest(observedRevision: reminder.mutationRevision))

        #expect(reminder.state == .active)
        #expect(reminder.progress.pending.count == 1)
        #expect(reminder.progress.pending.first?.originalTarget == 8)
        #expect(reminder.progress.scheduledCount == 1)
        #expect(reminder.progress.skippedCount == 1)
        #expect(reminder.progress.latestHandled == nil)
    }

    @Test func downwardCounterChangesKeepPendingOccurrencesAndDoNotReopenHandledOnes() throws {
        let reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .repeating(kind: .increase, firstTarget: 12, interval: 4, limit: nil, text: nil),
            createdAt: .now
        ))
        let triggered = KnittingReminderEvaluator.evaluate(oldValue: 10, newValue: 20, reminders: [reminder])
        let pendingBeforeDecrease = try #require(triggered.reminders.first?.progress.pending)

        let decreased = KnittingReminderEvaluator.evaluate(oldValue: 20, newValue: 3, reminders: triggered.reminders)

        #expect(decreased.pending.isEmpty)
        #expect(decreased.reminders.first?.progress.pending == pendingBeforeDecrease)
        #expect(decreased.reminders.first?.progress.scheduledCount == 3)
    }

    @Test func repeatingRuleStopsSchedulingWhenTheNextTargetWouldOverflow() throws {
        let reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .repeating(kind: .cable, firstTarget: .max - 1, interval: 2, limit: nil, text: nil),
            createdAt: .now
        ))

        let result = KnittingReminderEvaluator.evaluate(oldValue: .max - 2, newValue: .max, reminders: [reminder])
        let updated = try #require(result.reminders.first)

        #expect(result.pending.map(\.originalTarget) == [.max - 1])
        #expect(updated.progress.scheduledCount == 1)
        #expect(updated.progress.nextTarget == nil)
    }

    @Test func directJumpSchedulesEveryCrossedRepeatingOccurrenceIndividually() throws {
        let reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .repeating(kind: .decrease, firstTarget: 12, interval: 5, limit: nil, text: nil),
            createdAt: .now
        ))

        let result = KnittingReminderEvaluator.evaluate(oldValue: 10, newValue: 35, reminders: [reminder])
        let updated = try #require(result.reminders.first)

        #expect(result.pending.map(\.originalTarget) == [12, 17, 22, 27, 32])
        #expect(updated.progress.pending.map(\.originalTarget) == [12, 17, 22, 27, 32])
        #expect(updated.progress.scheduledCount == 5)
        #expect(updated.progress.nextTarget == 37)
    }

    @Test func actionsRejectStaleRevisions() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .buttonhole, target: 4, text: nil),
            createdAt: .now
        ))
        reminder = try reminder.applying(.trigger(through: 4))
        let occurrence = try #require(reminder.progress.pending.first)

        let staleRevision = reminder.mutationRevision &+ 1
        #expect(throws: KnittingReminderMutationError.staleRevision) {
            try reminder.applying(.complete(occurrenceID: occurrence.id, observedRevision: staleRevision))
        }
    }
}
