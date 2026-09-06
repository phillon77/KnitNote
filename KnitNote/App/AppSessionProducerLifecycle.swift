enum AppSessionProducerDrainError: Error, Equatable {
    case producerStillActive
}

@MainActor
protocol AppSessionProducer: AnyObject {
    func stopForSessionTransition()
    func waitForStoppedOperations() async throws
}
