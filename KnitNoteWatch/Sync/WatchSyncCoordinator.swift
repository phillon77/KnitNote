#if os(watchOS)
import Combine
import Foundation

@MainActor
final class WatchSyncCoordinator: ObservableObject {
    @Published private(set) var snapshot: WatchSyncSnapshot?
    @Published private(set) var pendingCount: Int
    @Published private(set) var selectedProjectID: UUID?
    @Published private(set) var selectedCounterID: UUID?
    @Published private(set) var localizedErrorReason: String?

    private let transport: any WatchConnectivityTransport
    private let cacheFile: AtomicWatchSyncFile<WatchSyncCache>
    private let now: () -> Date
    private let localize: (String) -> String

    private var state: WatchOptimisticState
    private var requiresSnapshot: Bool
    private var isStarted = false
    private var isHandshakeInFlight = false
    private var reachableHandshakeCompleted = false
    private var interactiveCommandID: UUID?

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
        selectedProjectID = state.selectedProjectID
        selectedCounterID = state.selectedCounterID
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        configureTransport()
        transport.activate()

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

    private func configureTransport() {
        transport.onActivationCompleted = { [weak self] activated, _ in
            guard let self, activated else { return }
            reachableHandshakeCompleted = false
            beginHandshakeAndReplay()
        }
        transport.onReachabilityChanged = { [weak self] reachable in
            guard let self, reachable else { return }
            reachableHandshakeCompleted = false
            beginHandshakeAndReplay()
        }
        transport.onTransferCompleted = { _, _ in
            // Delivery is not authority. The durable queue changes only for a
            // matching command response from the iPhone.
        }
        transport.onReceivedEnvelope = { [weak self] envelope, _ in
            self?.receive(envelope)
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

        if transport.isReachable, reachableHandshakeCompleted {
            sendNextPendingInteractively()
        } else {
            if transport.isReachable {
                beginHandshakeAndReplay(transferPendingCommands: false)
            }
            transport.transferUserInfo(.command(command))
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
            interactiveCommandID = nil
            return
        }

        if interactiveCommandID == acknowledgement.commandID {
            interactiveCommandID = nil
        }
        if let rejection = acknowledgement.rejection {
            setError(rejection)
        } else {
            localizedErrorReason = nil
        }
        sendNextPendingInteractively()
    }

    private func beginHandshakeAndReplay(transferPendingCommands: Bool = true) {
        let handshake = WatchConnectivityEnvelope.queueHandshake(
            state.pendingCommands.map(\.id)
        )
        transport.transferUserInfo(handshake)
        if transferPendingCommands {
            for command in state.pendingCommands {
                transport.transferUserInfo(.command(command))
            }
        }

        guard transport.isReachable, !isHandshakeInFlight else { return }
        isHandshakeInFlight = true
        transport.sendMessage(
            handshake,
            reply: { [weak self] envelope in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    isHandshakeInFlight = false
                    receive(envelope)
                    reachableHandshakeCompleted = true
                    sendNextPendingInteractively()
                }
            },
            failure: { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isHandshakeInFlight = false
                }
            }
        )
    }

    private func sendNextPendingInteractively() {
        guard reachableHandshakeCompleted,
              transport.isReachable,
              interactiveCommandID == nil,
              let command = state.pendingCommands.first
        else {
            return
        }

        interactiveCommandID = command.id
        transport.sendMessage(
            .command(command),
            reply: { [weak self] envelope in
                Task { @MainActor [weak self] in
                    guard let self, interactiveCommandID == command.id else { return }
                    receive(envelope)
                    if interactiveCommandID == command.id {
                        interactiveCommandID = nil
                    }
                }
            },
            failure: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard self?.interactiveCommandID == command.id else { return }
                    self?.interactiveCommandID = nil
                }
            }
        )
        transport.transferUserInfo(.command(command))
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
