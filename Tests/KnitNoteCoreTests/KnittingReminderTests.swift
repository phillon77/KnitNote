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

    @Test func draftInputValidationIdentifiesTheExactInvalidBoundaryField() {
        #expect(KnittingReminderDraftValidation.issue(
            firstTarget: 0,
            isRepeating: false,
            interval: nil,
            hasFiniteLimit: false,
            limit: nil
        ) == nil)
        #expect(KnittingReminderDraftValidation.issue(
            firstTarget: -1,
            isRepeating: false,
            interval: nil,
            hasFiniteLimit: false,
            limit: nil
        ) == .firstTarget)
        #expect(KnittingReminderDraftValidation.issue(
            firstTarget: 8,
            isRepeating: true,
            interval: 0,
            hasFiniteLimit: false,
            limit: nil
        ) == .interval)
        #expect(KnittingReminderDraftValidation.issue(
            firstTarget: 8,
            isRepeating: true,
            interval: -1,
            hasFiniteLimit: false,
            limit: nil
        ) == .interval)
        #expect(KnittingReminderDraftValidation.issue(
            firstTarget: 8,
            isRepeating: true,
            interval: 1,
            hasFiniteLimit: true,
            limit: 0
        ) == .limit)
        #expect(KnittingReminderDraftValidation.issue(
            firstTarget: 8,
            isRepeating: true,
            interval: 1,
            hasFiniteLimit: true,
            limit: -1
        ) == .limit)
        #expect(KnittingReminderDraftValidation.issue(
            firstTarget: 8,
            isRepeating: true,
            interval: 1,
            hasFiniteLimit: true,
            limit: 1
        ) == nil)
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
        let nextRow = KnittingReminderEvaluator.evaluate(oldValue: 20, newValue: 21, reminders: [reminder])
        let reappeared = try #require(nextRow.reminders.first)
        #expect(nextRow.pending.map(\.id) == [occurrence.id])
        #expect(reappeared.visibleOccurrences(at: 21).first?.phase == .deferredOnce)
        #expect(throws: KnittingReminderMutationError.alreadyDeferred) {
            try reappeared.applying(.deferOnce(occurrenceID: occurrence.id, observedRevision: reappeared.mutationRevision))
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

    @Test func evaluatorIgnoresRepeatingTargetsThatWereAlreadyPastBeforeThisIncrement() throws {
        let reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .repeating(kind: .increase, firstTarget: 5, interval: 5, limit: nil, text: nil),
            createdAt: .now
        ))

        let result = KnittingReminderEvaluator.evaluate(oldValue: 10, newValue: 11, reminders: [reminder])
        let updated = try #require(result.reminders.first)

        #expect(result.pending.isEmpty)
        #expect(updated.progress.pending.isEmpty)
        #expect(updated.progress.scheduledCount == 0)
        #expect(updated.progress.nextTarget == 15)
    }

    @Test func deferAfterDirectJumpWaitsForTheNextActualIncreaseAndThenCanBeSkipped() throws {
        let reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .changeYarn, target: 12, text: nil),
            createdAt: .now
        ))
        let jumped = KnittingReminderEvaluator.evaluate(oldValue: 10, newValue: 35, reminders: [reminder])
        var deferred = try #require(jumped.reminders.first)
        let occurrence = try #require(deferred.progress.pending.first)

        deferred = try deferred.applying(.deferOnce(
            occurrenceID: occurrence.id,
            observedRevision: deferred.mutationRevision
        ))
        #expect(deferred.visibleOccurrences(at: 35).isEmpty)
        #expect(deferred.progress.pending.first?.displayAt == 36)

        let nextRow = KnittingReminderEvaluator.evaluate(oldValue: 35, newValue: 36, reminders: [deferred])
        let presented = try #require(nextRow.reminders.first)
        #expect(presented.visibleOccurrences(at: 36).first?.phase == .deferredOnce)
        #expect(throws: KnittingReminderMutationError.alreadyDeferred) {
            try presented.applying(.deferOnce(
                occurrenceID: occurrence.id,
                observedRevision: presented.mutationRevision
            ))
        }

        let skipped = try presented.applying(.skip(
            occurrenceID: occurrence.id,
            observedRevision: presented.mutationRevision
        ))
        #expect(skipped.state == .completed)
        #expect(skipped.progress.skippedCount == 1)
        #expect(skipped.progress.pending.isEmpty)
    }

    @Test func codableRoundTripPreservesProgressAndRejectsCorruptCounts() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .repeating(kind: .cable, firstTarget: 4, interval: 3, limit: nil, text: "twist"),
            createdAt: Date(timeIntervalSince1970: 12)
        ))
        reminder = try reminder.applying(.trigger(through: 7))
        let data = try JSONEncoder().encode(reminder)

        #expect(try JSONDecoder().decode(KnittingReminder.self, from: data) == reminder)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var progress = try #require(object["progress"] as? [String: Any])
        progress["scheduledCount"] = -1
        object["progress"] = progress
        let corrupt = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KnittingReminder.self, from: corrupt)
        }
    }

    @Test func decodingRejectsDuplicatePendingOccurrenceIDs() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .repeating(kind: .cable, firstTarget: 4, interval: 3, limit: nil, text: nil),
            createdAt: .now
        ))
        reminder = try reminder.applying(.trigger(through: 7))

        let data = try JSONEncoder().encode(reminder)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var progress = try #require(object["progress"] as? [String: Any])
        var pending = try #require(progress["pending"] as? [[String: Any]])
        let firstID = try #require(pending.first?["id"])
        #expect(pending.count == 2)
        pending[1]["id"] = firstID
        progress["pending"] = pending
        object["progress"] = progress

        let corrupt = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KnittingReminder.self, from: corrupt)
        }
    }

    @Test func decodingRejectsPendingAndLatestHandledOccurrenceIDCollision() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .repeating(kind: .cable, firstTarget: 4, interval: 3, limit: nil, text: nil),
            createdAt: .now
        ))
        reminder = try reminder.applying(.trigger(through: 7))
        let first = try #require(reminder.progress.pending.first)
        reminder = try reminder.applying(.skip(occurrenceID: first.id, observedRevision: reminder.mutationRevision))

        let data = try JSONEncoder().encode(reminder)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var progress = try #require(object["progress"] as? [String: Any])
        let pending = try #require(progress["pending"] as? [[String: Any]])
        let pendingID = try #require(pending.first?["id"])
        var latestHandled = try #require(progress["latestHandled"] as? [String: Any])
        latestHandled["id"] = pendingID
        progress["latestHandled"] = latestHandled
        object["progress"] = progress

        let corrupt = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KnittingReminder.self, from: corrupt)
        }
    }

    @Test func exhaustedRevisionRejectsMutationsWithoutWrappingToZero() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .buttonhole, target: 4, text: nil),
            createdAt: .now
        ))
        reminder = try reminder.applying(.trigger(through: 4))
        let occurrence = try #require(reminder.progress.pending.first)
        let encoded = try JSONEncoder().encode(reminder)
        let source = try #require(String(data: encoded, encoding: .utf8))
        let exhaustedData = try #require(source.replacingOccurrences(
            of: "\"mutationRevision\":1",
            with: "\"mutationRevision\":18446744073709551615"
        ).data(using: .utf8))
        let exhausted = try JSONDecoder().decode(KnittingReminder.self, from: exhaustedData)

        #expect(throws: KnittingReminderMutationError.revisionExhausted) {
            try exhausted.applying(.complete(occurrenceID: occurrence.id, observedRevision: .max))
        }
    }

    @Test func resetAndRehandledOccurrenceRoundTripsThroughCodable() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .measure, target: 6, text: nil),
            createdAt: .now
        ))
        reminder = try reminder.applying(.trigger(through: 6))
        let first = try #require(reminder.progress.pending.first)
        reminder = try reminder.applying(.skip(occurrenceID: first.id, observedRevision: reminder.mutationRevision))
        reminder = try reminder.applying(.resetLatest(observedRevision: reminder.mutationRevision))
        let reset = try #require(reminder.progress.pending.first)
        reminder = try reminder.applying(.complete(occurrenceID: reset.id, observedRevision: reminder.mutationRevision))

        let decoded = try JSONDecoder().decode(KnittingReminder.self, from: JSONEncoder().encode(reminder))
        #expect(decoded == reminder)
        #expect(decoded.progress.scheduledCount == 1)
        #expect(decoded.progress.skippedCount == 1)
        #expect(decoded.progress.completedCount == 1)
    }

    @Test func deferredOccurrenceReappearsOnTheNextUpwardChangeAfterADecrease() throws {
        let reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .changeYarn, target: 12, text: nil),
            createdAt: .now
        ))
        let jumped = KnittingReminderEvaluator.evaluate(oldValue: 10, newValue: 35, reminders: [reminder])
        var deferred = try #require(jumped.reminders.first)
        let occurrence = try #require(deferred.progress.pending.first)
        deferred = try deferred.applying(.deferOnce(
            occurrenceID: occurrence.id,
            observedRevision: deferred.mutationRevision
        ))

        let decreased = KnittingReminderEvaluator.evaluate(oldValue: 35, newValue: 0, reminders: [deferred])
        let afterDecrease = try #require(decreased.reminders.first)
        #expect(afterDecrease.visibleOccurrences(at: 0).isEmpty)

        let nextIncrease = KnittingReminderEvaluator.evaluate(oldValue: 0, newValue: 1, reminders: [afterDecrease])
        let reappeared = try #require(nextIncrease.reminders.first)
        #expect(nextIncrease.pending.map(\.id) == [occurrence.id])
        #expect(reappeared.visibleOccurrences(at: 1).first?.phase == .deferredOnce)
        #expect(throws: KnittingReminderMutationError.alreadyDeferred) {
            try reappeared.applying(.deferOnce(
                occurrenceID: occurrence.id,
                observedRevision: reappeared.mutationRevision
            ))
        }
    }

    @Test func deferredOccurrenceRoundTripsAndReleasesOnTheNextUpwardChange() throws {
        let reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .changeYarn, target: 12, text: nil),
            createdAt: .now
        ))
        let jumped = KnittingReminderEvaluator.evaluate(oldValue: 10, newValue: 35, reminders: [reminder])
        var deferred = try #require(jumped.reminders.first)
        let occurrence = try #require(deferred.progress.pending.first)
        deferred = try deferred.applying(.deferOnce(
            occurrenceID: occurrence.id,
            observedRevision: deferred.mutationRevision
        ))

        let decoded = try JSONDecoder().decode(KnittingReminder.self, from: JSONEncoder().encode(deferred))
        #expect(decoded == deferred)
        #expect(decoded.progress.pending.first?.awaitsNextUpwardChange == true)
        #expect(decoded.visibleOccurrences(at: 35).isEmpty)

        let nextIncrease = KnittingReminderEvaluator.evaluate(oldValue: 35, newValue: 36, reminders: [decoded])
        let reappeared = try #require(nextIncrease.reminders.first)
        #expect(nextIncrease.pending.map(\.id) == [occurrence.id])
        #expect(reappeared.visibleOccurrences(at: 36).first?.phase == .deferredOnce)
        #expect(reappeared.progress.pending.first?.awaitsNextUpwardChange == false)
    }

    @Test func evaluatorReportsRevisionExhaustionWithoutSilentlyDiscardingTheUpdate() throws {
        var reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .buttonhole, target: 4, text: nil),
            createdAt: .now
        ))
        reminder = try reminder.applying(.trigger(through: 4))
        let encoded = try JSONEncoder().encode(reminder)
        let source = try #require(String(data: encoded, encoding: .utf8))
        let exhaustedData = try #require(source.replacingOccurrences(
            of: "\"mutationRevision\":1",
            with: "\"mutationRevision\":18446744073709551615"
        ).data(using: .utf8))
        let exhausted = try JSONDecoder().decode(KnittingReminder.self, from: exhaustedData)

        let result = KnittingReminderEvaluator.evaluate(oldValue: 4, newValue: 5, reminders: [exhausted])

        #expect(result.rejectedReminderIDs == [exhausted.id])
        #expect(result.reminders == [exhausted])
        #expect(result.pending.isEmpty)
    }
}
