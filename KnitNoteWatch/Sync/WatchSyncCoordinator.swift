#if os(watchOS)
import Combine
import Foundation

@MainActor
final class WatchSyncCoordinator: ObservableObject {
    @Published private(set) var snapshot: WatchSyncSnapshot?
    @Published private(set) var pendingCount: Int
    @Published private(set) var pendingCounterIDs: Set<UUID>
    @Published private(set) var selectedProjectID: UUID?
    @Published private(set) var selectedCounterID: UUID?
    @Published private(set) var localizedErrorReason: String?

    private let transport: any WatchConnectivityTransport
    private let cacheFile: AtomicWatchSyncFile<WatchSyncCache>
    private let now: () -> Date
    private let localize: (String) -> String

    private var state: WatchOptimisticState
    private var deliveryState = WatchHeadDeliveryState()
    private var requiresSnapshot: Bool
    private var isConfigured = false
    private var isActivating = false
    private var isActivated = false
    private var reachableHandshakeCompleted = false
    private var handshakeAttemptID: UUID?
    private var activationRetryTask: Task<Void, Never>?
    private var handshakeRetryTask: Task<Void, Never>?

    init(
        transport: (any WatchConnectivityTransport)? = nil,
        applicationSupportRoot: URL? = nil,
        now: @escaping () -> Date = { .now },
        localize: @escaping (String) -> String = {
            String(localized: String.LocalizationValue($0))
        }
    ) {
        self.transport = transport ?? WatchSession()
        let liveRoot = applicationSupportRoot ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnitNote", isDirectory: true)
        cacheFile = AtomicWatchSyncFile(url: WatchSyncPaths.watchCache(in: liveRoot))
        self.now = now
        self.localize = localize

        let recovery: WatchSyncCacheRecovery
        do {
            recovery = try WatchSyncCache.loadRecoveringCorruption(in: liveRoot)
            localizedErrorReason = nil
        } catch {
            recovery = WatchSyncCacheRecovery(cache: .empty, requiresSnapshot: true)
            localizedErrorReason = localize(WatchCommandRejection.storageFailure.localizationKey)
        }

        state = WatchOptimisticState(cache: recovery.cache)
        requiresSnapshot = recovery.requiresSnapshot
        snapshot = state.snapshot
        pendingCount = state.pendingCommands.count
        pendingCounterIDs = state.pendingCounterIDs
        selectedProjectID = state.selectedProjectID
        selectedCounterID = state.selectedCounterID
    }

    func start() {
        configureOnce()
        activate()

        if requiresSnapshot {
            requestSnapshotInBackground()
        }
    }

    func increment(projectID: UUID, counterID: UUID) {
        enqueue(projectID: projectID, counterID: counterID, operation: .increment)
    }

    func decrement(projectID: UUID, counterID: UUID) {
        enqueue(projectID: projectID, counterID: counterID, operation: .decrement)
    }

    func reset(projectID: UUID, counterID: UUID) {
        enqueue(projectID: projectID, counterID: counterID, operation: .reset)
    }

    func hasPending(projectID: UUID, counterID: UUID) -> Bool {
        state.hasPending(projectID: projectID, counterID: counterID)
    }

    func selectProject(_ projectID: UUID?) {
        var candidate = state
        guard candidate.selectProject(projectID) else { return }
        persistThenPublish(candidate)
    }

    func selectCounter(_ counterID: UUID?) {
        var candidate = state
        guard candidate.selectCounter(counterID) else { return }
        persistThenPublish(candidate)
    }

    func receive(_ envelope: WatchConnectivityEnvelope) {
        switch envelope {
        case .snapshotRequest:
            beginHandshakeAndReplay()
        case let .snapshot(snapshot):
            replaceSnapshot(snapshot)
        case .command:
            break
        case let .acknowledgement(acknowledgement):
            handleAcknowledgement(acknowledgement)
        case .queueHandshake:
            break
        }
    }

    private func configureOnce() {
        guard !isConfigured else { return }
        isConfigured = true

        transport.onActivationCompleted = { [weak self] activated, _ in
            guard let self else { return }
            invalidateDeliveryAttempts()
            isActivating = false
            isActivated = activated
            if activated {
                activationRetryTask?.cancel()
                activationRetryTask = nil
                beginHandshakeAndReplay()
            } else {
                scheduleActivationRetry()
            }
        }
        transport.onReachabilityChanged = { [weak self] reachable in
            guard let self else { return }
            invalidateDeliveryAttempts()
            guard reachable else {
                return
            }
            beginHandshakeAndReplay()
        }
        transport.onTransferCompleted = { [weak self] envelope, error in
            guard let self,
                  error != nil,
                  case let .command(command)? = envelope,
                  deliveryState.failBackgroundTransfer(for: command.id)
            else { return }
            // Transfer completion is not authority. A failed matching head is
            // retried after a bounded delay and remains durably queued.
            scheduleHandshakeRetry()
        }
        transport.onReceivedEnvelope = { [weak self] envelope, _ in
            self?.receive(envelope)
        }
    }

    private func invalidateDeliveryAttempts() {
        reachableHandshakeCompleted = false
        handshakeAttemptID = nil
        deliveryState.cancelInteractiveDelivery()
    }

    private func activate() {
        guard isConfigured, !isActivating, !isActivated else { return }
        isActivating = true
        transport.activate()
    }

    private func scheduleActivationRetry() {
        guard activationRetryTask == nil else { return }
        activationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            activationRetryTask = nil
            activate()
        }
    }

    private func enqueue(
        projectID: UUID,
        counterID: UUID,
        operation: WatchCounterOperation
    ) {
        let command = WatchCounterCommand(
            projectID: projectID,
            counterID: counterID,
            operation: operation,
            createdAt: now()
        )
        var candidate = state
        if let rejection = candidate.enqueue(command) {
            setError(rejection)
            return
        }

        guard persistThenPublish(candidate) else { return }
        localizedErrorReason = nil

        if reachableHandshakeCompleted {
            deliverHeadIfNeeded()
        } else {
            beginHandshakeAndReplay()
        }
    }

    @discardableResult
    private func persistThenPublish(_ candidate: WatchOptimisticState) -> Bool {
        do {
            try cacheFile.save(candidate.cache)
            state = candidate
            publish(candidate)
            return true
        } catch {
            setError(.storageFailure)
            return false
        }
    }

    private func publish(_ candidate: WatchOptimisticState) {
        snapshot = candidate.snapshot
        pendingCount = candidate.pendingCommands.count
        pendingCounterIDs = candidate.pendingCounterIDs
        selectedProjectID = candidate.selectedProjectID
        selectedCounterID = candidate.selectedCounterID
    }

    private func replaceSnapshot(_ snapshot: WatchSyncSnapshot) {
        var candidate = state
        candidate.replaceSnapshot(snapshot)
        guard persistThenPublish(candidate) else { return }
        requiresSnapshot = false
    }

    private func handleAcknowledgement(_ acknowledgement: WatchCommandAcknowledgement) {
        var candidate = state
        guard candidate.acknowledge(acknowledgement) else { return }
        guard persistThenPublish(candidate) else {
            deliveryState.cancelInteractiveDelivery()
            reachableHandshakeCompleted = false
            beginHandshakeAndReplay()
            return
        }

        _ = deliveryState.acknowledge(acknowledgement.commandID)
        if let rejection = acknowledgement.rejection {
            setError(rejection)
        } else {
            localizedErrorReason = nil
        }
        deliverHeadIfNeeded()
    }

    private func beginHandshakeAndReplay() {
        reachableHandshakeCompleted = false
        deliveryState.cancelInteractiveDelivery()
        let handshake = WatchConnectivityEnvelope.queueHandshake(
            state.pendingCommands.map(\.id)
        )
        transport.transferUserInfo(handshake)
        deliverHeadIfNeeded()

        guard transport.isReachable, handshakeAttemptID == nil else { return }
        let attemptID = UUID()
        handshakeAttemptID = attemptID
        transport.sendMessage(
            handshake,
            reply: { [weak self] envelope in
                Task { @MainActor [weak self] in
                    guard let self, handshakeAttemptID == attemptID else { return }
                    handshakeAttemptID = nil
                    handshakeRetryTask?.cancel()
                    handshakeRetryTask = nil
                    receive(envelope)
                    reachableHandshakeCompleted = true
                    deliverHeadIfNeeded()
                }
            },
            failure: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, handshakeAttemptID == attemptID else { return }
                    handshakeAttemptID = nil
                    scheduleHandshakeRetry()
                }
            }
        )
    }

    private func deliverHeadIfNeeded() {
        guard let command = state.nextPendingCommand else { return }

        if deliveryState.prepareBackgroundTransfer(for: command.id) {
            transport.transferUserInfo(.command(command))
        }

        guard reachableHandshakeCompleted, transport.isReachable else { return }
        let attemptID = UUID()
        guard deliveryState.beginInteractiveDelivery(
            for: command.id,
            attemptID: attemptID
        ) != nil else { return }

        transport.sendMessage(
            .command(command),
            reply: { [weak self] envelope in
                Task { @MainActor [weak self] in
                    guard let self, deliveryState.finishInteractiveDelivery(
                        commandID: command.id,
                        attemptID: attemptID
                    ) else { return }

                    switch envelope {
                    case let .acknowledgement(acknowledgement)
                        where acknowledgement.commandID == command.id:
                        receive(envelope)
                    case .snapshot:
                        receive(envelope)
                        beginHandshakeAndReplay()
                    default:
                        receive(envelope)
                        beginHandshakeAndReplay()
                    }
                }
            },
            failure: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, deliveryState.finishInteractiveDelivery(
                        commandID: command.id,
                        attemptID: attemptID
                    ) else { return }
                    beginHandshakeAndReplay()
                }
            }
        )
    }

    private func scheduleHandshakeRetry() {
        guard handshakeRetryTask == nil else { return }
        handshakeRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            handshakeRetryTask = nil
            beginHandshakeAndReplay()
        }
    }

    private func requestSnapshotInBackground() {
        let request = WatchConnectivityEnvelope.snapshotRequest
        try? transport.updateApplicationContext(request)
        transport.transferUserInfo(request)
    }

    private func setError(_ rejection: WatchCommandRejection) {
        localizedErrorReason = localize(rejection.localizationKey)
    }
}

private extension WatchCommandRejection {
    var localizationKey: String {
        switch self {
        case .unsupportedSchema:
            "watch.sync.error.unsupportedSchema"
        case .projectMissing:
            "watch.sync.error.projectMissing"
        case .counterMissing:
            "watch.sync.error.counterMissing"
        case .projectCompleted:
            "watch.sync.error.projectCompleted"
        case .storageFailure:
            "watch.sync.error.storageFailure"
        }
    }
}
#endif
