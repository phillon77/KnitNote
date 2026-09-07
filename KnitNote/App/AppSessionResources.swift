import Foundation

@MainActor
/// A fixed local composition. Producers and their store cannot be rebound.
final class AppSessionResources: Identifiable, AppSessionProducer {
    let id = UUID()
    let store: JSONProjectStore
    let presentation: AppSessionPresentationResources?
    private let group: AppSessionProducerGroup
    private(set) var isStopped = false

    init(
        store: JSONProjectStore,
        presentation: AppSessionPresentationResources? = nil,
        makeProducers: (JSONProjectStore) -> [any AppSessionProducer]
    ) throws {
        guard !store.isSessionWriteRevoked else { throw AppSessionOwner.Failure.stoppedSession }
        self.store = store
        self.presentation = presentation
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
