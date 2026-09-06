import Combine
import Foundation
import Testing
@testable import KnitNote

@MainActor
@Suite struct PatternInboxProcessorSessionTests {
    @Test(arguments: [ProducerTestLateResult.created, .selection, .failure])
    func stoppedProcessorSuppressesLateResult(
        _ lateResult: ProducerTestLateResult
    ) async throws {
        let item = producerTestInboxItem()
        let fixture = try ProducerTestInboxFixture(
            item: item,
            result: lateResult.result(item: item)
        )
        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        fixture.processor.stopForSessionTransition()

        let entered = AsyncStream<Void>.makeStream()
        var drained = false
        let waiter = Task { @MainActor in
            entered.continuation.yield(())
            try await fixture.processor.waitForStoppedOperations()
            drained = true
        }

        do {
            var observed = entered.stream.makeAsyncIterator()
            _ = await observed.next()
            #expect(!drained)
            await fixture.processing.release()
            try await waiter.value
        } catch {
            await fixture.processing.release()
            waiter.cancel()
            _ = try? await waiter.value
            fixture.cleanup()
            throw error
        }

        #expect(drained)
        #expect(fixture.processor.pendingSelection == nil)
        #expect(fixture.processor.failure == nil)
        #expect(fixture.processor.notice == nil)
        #expect(!fixture.presenter.isPresented)
        fixture.cleanup()
    }

    @Test func normalSuccessPublishesNoticeBeforeStop() async throws {
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID()))
        )
        let events = AsyncStream<PatternInboxNotice>.makeStream()
        let observation = fixture.processor.$notice.compactMap { $0 }.sink {
            events.continuation.yield($0)
        }
        var iterator = events.stream.makeAsyncIterator()

        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        await fixture.processing.release()

        guard let notice = await iterator.next() else {
            observation.cancel()
            fixture.processor.stopForSessionTransition()
            _ = try? await fixture.processor.waitForStoppedOperations()
            fixture.cleanup()
            Issue.record("The normal success path did not publish a notice")
            return
        }
        #expect(notice.importCount == 1)
        #expect(fixture.presenter.isPresented)

        observation.cancel()
        fixture.processor.stopForSessionTransition()
        do {
            try await fixture.processor.waitForStoppedOperations()
        } catch {
            await fixture.stopDrainAndCleanup()
            throw error
        }
        fixture.cleanup()
    }

    @Test func synchronousNoticeSubscriberStopRestoresClearedNotice() async throws {
        let delay = ProducerTestNoticeDelay(mode: .suspendAll)
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID())),
            noticeDelay: { await delay.wait() }
        )
        let stopped = AsyncStream<Void>.makeStream()
        let observation = fixture.processor.$notice.compactMap { $0 }.sink { _ in
            fixture.processor.stopForSessionTransition()
            stopped.continuation.yield(())
        }

        await delay.releaseAll()
        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        await fixture.processing.release()
        var stoppedIterator = stopped.stream.makeAsyncIterator()
        _ = await stoppedIterator.next()
        do {
            try await fixture.processor.waitForStoppedOperations()
        } catch {
            observation.cancel()
            await delay.releaseAll()
            await fixture.stopDrainAndCleanup()
            throw error
        }

        await delay.releaseAll()
        #expect(fixture.processor.notice == nil)
        #expect(fixture.processor.pendingSelection == nil)
        #expect(fixture.processor.failure == nil)
        observation.cancel()
        fixture.cleanup()
    }

    @Test func synchronousPresenterSubscriberStopRestoresStoppedPresentation() async throws {
        let delay = ProducerTestNoticeDelay(mode: .suspendAll)
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID())),
            noticeDelay: { await delay.wait() }
        )
        let stopped = AsyncStream<Void>.makeStream()
        let observation = fixture.presenter.$isPresented.filter { $0 }.sink { _ in
            fixture.processor.stopForSessionTransition()
            stopped.continuation.yield(())
        }

        await delay.releaseAll()
        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        await fixture.processing.release()
        var stoppedIterator = stopped.stream.makeAsyncIterator()
        _ = await stoppedIterator.next()
        do {
            try await fixture.processor.waitForStoppedOperations()
        } catch {
            observation.cancel()
            await delay.releaseAll()
            await fixture.stopDrainAndCleanup()
            throw error
        }

        await delay.releaseAll()
        #expect(!fixture.presenter.isPresented)
        #expect(fixture.processor.notice == nil)
        #expect(fixture.processor.pendingSelection == nil)
        #expect(fixture.processor.failure == nil)
        observation.cancel()
        fixture.cleanup()
    }

    @Test func synchronousPresenterDismissAfterStopPreservesBackupSettingsRequest() async throws {
        let delay = ProducerTestNoticeDelay(mode: .suspendAll)
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID())),
            noticeDelay: { await delay.wait() }
        )
        let stopped = AsyncStream<Void>.makeStream()
        var handledPresentation = false
        let observation = fixture.presenter.$isPresented.filter { $0 }.sink { _ in
            guard !handledPresentation else { return }
            handledPresentation = true
            fixture.processor.stopForSessionTransition()
            fixture.presenter.dismiss(openBackupSettings: true)
            stopped.continuation.yield(())
        }

        await delay.releaseAll()
        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        await fixture.processing.release()
        var stoppedIterator = stopped.stream.makeAsyncIterator()
        _ = await stoppedIterator.next()
        do {
            try await fixture.processor.waitForStoppedOperations()
        } catch {
            observation.cancel()
            await delay.releaseAll()
            await fixture.stopDrainAndCleanup()
            throw error
        }

        await delay.releaseAll()
        #expect(!fixture.presenter.isPresented)
        #expect(fixture.presenter.isShowingBackupSettings)
        #expect(BackupHistory(defaults: fixture.defaults).hasShownPatternReminder)
        #expect(fixture.processor.notice == nil)
        #expect(fixture.processor.pendingSelection == nil)
        #expect(fixture.processor.failure == nil)
        observation.cancel()
        fixture.cleanup()
    }

    @Test func replacementNoticeTaskRemainsOwnedUntilItActuallyStops() async throws {
        let delay = ProducerTestNoticeDelay(mode: .suspendFirstOnly)
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID())),
            noticeDelay: { await delay.wait() }
        )
        let notices = AsyncStream<PatternInboxNotice>.makeStream()
        let observation = fixture.processor.$notice.compactMap { $0 }.sink {
            notices.continuation.yield($0)
        }
        let latestTaskFinished = AsyncStream<Void>.makeStream()
        let completionObservation = fixture.processor.$notice
            .dropFirst()
            .filter { $0 == nil }
            .sink { _ in latestTaskFinished.continuation.yield(()) }
        var iterator = notices.stream.makeAsyncIterator()
        var latestTaskFinishedIterator = latestTaskFinished.stream.makeAsyncIterator()

        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        await fixture.processing.release()
        _ = await iterator.next()
        await delay.waitUntilCallCount(1)

        fixture.processor.processPending()
        _ = await iterator.next()
        await delay.waitUntilCallCount(2)
        _ = await latestTaskFinishedIterator.next()
        #expect((await delay.snapshot()).completionCount == 1)
        fixture.processor.stopForSessionTransition()

        let entered = AsyncStream<Void>.makeStream()
        var drained = false
        let waiter = Task { @MainActor in
            entered.continuation.yield(())
            try await fixture.processor.waitForStoppedOperations()
            drained = true
        }

        do {
            var enteredIterator = entered.stream.makeAsyncIterator()
            _ = await enteredIterator.next()
            #expect(!drained)
            await delay.release(call: 1)
            try await waiter.value
        } catch {
            await delay.releaseAll()
            waiter.cancel()
            _ = try? await waiter.value
            observation.cancel()
            completionObservation.cancel()
            fixture.cleanup()
            throw error
        }

        #expect(drained)
        #expect((await delay.snapshot()).completionCount == 2)
        observation.cancel()
        completionObservation.cancel()
        fixture.cleanup()
    }

    @Test func waitingBeforeStopRejectsTheOpenProducer() async throws {
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID()))
        )

        await #expect(throws: AppSessionProducerDrainError.producerStillActive) {
            try await fixture.processor.waitForStoppedOperations()
        }

        fixture.processor.stopForSessionTransition()
        try await fixture.processor.waitForStoppedOperations()
        fixture.cleanup()
    }

    @Test func repeatedStopIsIdempotent() async throws {
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID()))
        )
        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        fixture.processor.stopForSessionTransition()
        fixture.processor.stopForSessionTransition()

        await fixture.processing.release()
        do {
            try await fixture.processor.waitForStoppedOperations()
        } catch {
            await fixture.stopDrainAndCleanup()
            throw error
        }
        let snapshot = await fixture.processing.snapshot()

        #expect(snapshot.processCallCount == 1)
        #expect(fixture.processor.pendingSelection == nil)
        #expect(fixture.processor.failure == nil)
        #expect(fixture.processor.notice == nil)
        fixture.cleanup()
    }

    @Test func stoppedEntryMethodsDoNotCallProcessing() async throws {
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID()))
        )
        fixture.processor.stopForSessionTransition()

        fixture.processor.processPending()
        fixture.processor.resolve(itemID: UUID(), resolution: .createNew)
        fixture.processor.retry()
        fixture.processor.dismissFailure()
        fixture.processor.discard()
        await fixture.processing.release()
        try await fixture.processor.waitForStoppedOperations()
        let mainActorFence = Task { @MainActor in () }
        await mainActorFence.value
        let snapshot = await fixture.processing.snapshot()

        #expect(snapshot == ProducerTestInboxProcessingSnapshot(
            pendingItemsCallCount: 0,
            processCallCount: 0,
            discardCallCount: 0
        ))
        #expect(fixture.processor.pendingSelection == nil)
        #expect(fixture.processor.failure == nil)
        fixture.cleanup()
    }

    @Test func twoWaitersBothRemainPendingUntilTheOwnedOperationStops() async throws {
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID()))
        )
        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        fixture.processor.stopForSessionTransition()

        let entered = AsyncStream<Int>.makeStream()
        var firstDrained = false
        var secondDrained = false
        let first = Task { @MainActor in
            entered.continuation.yield(1)
            try await fixture.processor.waitForStoppedOperations()
            firstDrained = true
        }
        let second = Task { @MainActor in
            entered.continuation.yield(2)
            try await fixture.processor.waitForStoppedOperations()
            secondDrained = true
        }

        do {
            var iterator = entered.stream.makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()
            #expect(!firstDrained)
            #expect(!secondDrained)
            await fixture.processing.release()
            try await first.value
            try await second.value
        } catch {
            await fixture.processing.release()
            first.cancel()
            second.cancel()
            _ = try? await first.value
            _ = try? await second.value
            fixture.cleanup()
            throw error
        }

        #expect(firstDrained)
        #expect(secondDrained)
        fixture.cleanup()
    }

    @Test func cancellingOneWaiterDoesNotCancelSharedWorkOrTheOtherWaiter() async throws {
        let fixture = try ProducerTestInboxFixture(
            result: .success(.created(patternID: UUID()))
        )
        fixture.processor.processPending()
        await fixture.processing.waitUntilProcessStarts()
        fixture.processor.stopForSessionTransition()

        let entered = AsyncStream<Int>.makeStream()
        var survivingWaiterDrained = false
        let cancelledWaiter = Task { @MainActor in
            entered.continuation.yield(1)
            try await fixture.processor.waitForStoppedOperations()
        }
        let survivingWaiter = Task { @MainActor in
            entered.continuation.yield(2)
            try await fixture.processor.waitForStoppedOperations()
            survivingWaiterDrained = true
        }

        do {
            var iterator = entered.stream.makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()
            cancelledWaiter.cancel()
            #expect(!survivingWaiterDrained)
            #expect((await fixture.processing.snapshot()).processCallCount == 1)
            await fixture.processing.release()
            await #expect(throws: CancellationError.self) {
                try await cancelledWaiter.value
            }
            try await survivingWaiter.value
        } catch {
            await fixture.processing.release()
            cancelledWaiter.cancel()
            survivingWaiter.cancel()
            _ = try? await cancelledWaiter.value
            _ = try? await survivingWaiter.value
            fixture.cleanup()
            throw error
        }

        #expect(survivingWaiterDrained)
        #expect((await fixture.processing.snapshot()).processCallCount == 1)
        fixture.cleanup()
    }
}

enum ProducerTestLateResult: CaseIterable, CustomTestStringConvertible, Sendable {
    case created
    case selection
    case failure

    var testDescription: String {
        switch self {
        case .created: "created"
        case .selection: "needsSelection"
        case .failure: "failure"
        }
    }

    func result(item: PatternInboxItem) -> Result<PatternImportOutcome, any Error> {
        switch self {
        case .created:
            .success(.created(patternID: UUID()))
        case .selection:
            .success(.needsSelection(
                itemID: item.id,
                candidatePatternIDs: [UUID()]
            ))
        case .failure:
            .failure(ProducerTestFailure.processingFailed)
        }
    }
}
