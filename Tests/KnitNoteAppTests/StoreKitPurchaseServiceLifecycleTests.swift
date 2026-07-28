import Testing
@testable import KnitNote

@Suite struct StoreKitPurchaseServiceLifecycleTests {
    @Test @MainActor func serviceReleaseCancelsTheTransactionUpdatesListener() async {
        let script = TransactionUpdatesScript()
        weak var releasedService: StoreKitPurchaseService?
        var service: StoreKitPurchaseService? = StoreKitPurchaseService(
            transactionUpdateListener: .init { _ in
                await script.listenUntilCancelled()
            }
        )
        releasedService = service

        for _ in 0..<100 {
            if await script.hasStarted() { break }
            await Task.yield()
        }
        let didStart = await script.hasStarted()
        #expect(didStart)

        service = nil
        for _ in 0..<100 {
            if await script.hasStopped() { break }
            await Task.yield()
        }

        #expect(releasedService == nil)
        let didStop = await script.hasStopped()
        #expect(didStop)
    }

    @Test @MainActor func verifiedTransactionUpdateIsPublishedToConsumers() async {
        let script = TransactionUpdatesScript()
        let service = StoreKitPurchaseService(
            transactionUpdateListener: .init { onVerifiedTransaction in
                await onVerifiedTransaction()
                await script.listenUntilCancelled()
            }
        )

        var iterator = service.entitlementUpdates.makeAsyncIterator()
        let update: Void? = await iterator.next()

        #expect(update != nil)
    }

    @Test @MainActor func transientAppTransactionFailureIsReportedAsUnavailable() async {
        let service = StoreKitPurchaseService(
            transactionUpdateListener: .init { _ in },
            entitlementSource: .init(
                lifetimeQualification: { .none },
                legacyQualification: { .unavailable }
            )
        )

        #expect(await service.currentQualification() == .unavailable)
    }

    @Test @MainActor func verifiedFreeAppTransactionIsAuthoritativeNone() async {
        let service = StoreKitPurchaseService(
            transactionUpdateListener: .init { _ in },
            entitlementSource: .init(
                lifetimeQualification: { .none },
                legacyQualification: { .none }
            )
        )

        #expect(await service.currentQualification() == .none)
    }

    @Test @MainActor func unavailableLifetimeLookupStopsBeforeAuthoritativeLegacyLookup() async {
        let legacy = QualificationCallProbe()
        let service = StoreKitPurchaseService(
            transactionUpdateListener: .init { _ in },
            entitlementSource: .init(
                lifetimeQualification: { .unavailable },
                legacyQualification: {
                    legacy.record()
                    return .none
                }
            )
        )

        #expect(await service.currentQualification() == .unavailable)
        #expect(legacy.callCount == 0)
    }
}

@MainActor
private final class QualificationCallProbe {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

private actor TransactionUpdatesScript {
    private var started = false
    private var stopped = false

    func listenUntilCancelled() async {
        started = true
        while !Task.isCancelled {
            await Task.yield()
        }
        stopped = true
    }

    func hasStarted() -> Bool { started }
    func hasStopped() -> Bool { stopped }
}
