@MainActor
final class AppSessionProducerGroup: AppSessionProducer {
    private let store: JSONProjectStore
    private let producers: [any AppSessionProducer]
    private var isStopped = false

    init(store: JSONProjectStore, producers: [any AppSessionProducer]) {
        self.store = store
        self.producers = producers
    }

    func stopForSessionTransition() {
        guard !isStopped else { return }
        isStopped = true
        store.revokeSessionWrites()
        for producer in producers {
            producer.stopForSessionTransition()
        }
    }

    /// Waits for these registered local producers and store operations only.
    /// Success is not complete App freeze, durable health or cleanup authority.
    func waitForStoppedOperations() async throws {
        guard isStopped else {
            throw AppSessionProducerDrainError.producerStillActive
        }
        try Task.checkCancellation()
        for producer in producers {
            try await producer.waitForStoppedOperations()
        }
        try await store.waitForTrackedBackgroundWritesAfterRevocation()
        try Task.checkCancellation()
    }
}
