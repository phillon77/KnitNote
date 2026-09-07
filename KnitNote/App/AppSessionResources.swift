import Foundation

@MainActor
/// A fixed local composition. Producers and their store cannot be rebound.
final class AppSessionResources: Identifiable, AppSessionProducer {
    let id = UUID()
    let store: JSONProjectStore
    private let group: AppSessionProducerGroup
    private(set) var isStopped = false

    init(store: JSONProjectStore, makeProducers: (JSONProjectStore) -> [any AppSessionProducer]) throws {
        guard !store.isSessionWriteRevoked else { throw AppSessionOwner.Failure.stoppedSession }
        self.store = store
        group = AppSessionProducerGroup(store: store, producers: makeProducers(store))
    }

    func stopForSessionTransition() {
        guard !isStopped else { return }
        isStopped = true
        group.stopForSessionTransition()
    }

    func waitForStoppedOperations() async throws {
        try await group.waitForStoppedOperations()
    }
}
