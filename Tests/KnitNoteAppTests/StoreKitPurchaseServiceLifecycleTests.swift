import Testing
@testable import KnitNote

@Suite struct StoreKitPurchaseServiceLifecycleTests {
    @Test @MainActor func serviceReleaseCancelsTheTransactionUpdatesListener() async {
        let script = TransactionUpdatesScript()
        weak var releasedService: StoreKitPurchaseService?
        var service: StoreKitPurchaseService? = StoreKitPurchaseService(
            transactionUpdateListener: .init { await script.listenUntilCancelled() }
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
