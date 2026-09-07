import Combine
import Foundation

@MainActor
final class PhoneWatchSyncCoordinator: ObservableObject, AppSessionProducer {
    private let projectStore: JSONProjectStore
    private let entitlementCoordinator: EntitlementCoordinator
    private let transport: any WatchConnectivityTransport
    private let ledgerURL: URL
    private let preparedCommandURL: URL
    private let languageCode: () -> String
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let callbackGate: AppSessionCallbackGate

    private var projectSubscription: AnyCancellable?
    private var entitlementSubscription: AnyCancellable?
    private var serialTask: Task<Void, Never> = Task {}
    private var activationRetryTask: Task<Void, Never>?
    private var reliableSnapshotRetryTask: Task<Void, Never>?
    private var entitlementExpiryTask: Task<Void, Never>?
    private var activationRetryToken: UUID?
    private var reliableSnapshotRetryToken: UUID?
    private var entitlementExpiryToken: UUID?
    private var stoppedTasks: [Task<Void, Never>] = []
    private var lastPublishedProjects: [WatchProjectSnapshot]?
    private var lastPublishedEntitlement: WatchEntitlementSnapshot?
    private var lastPublishedLanguageCode: String?
    private var reliableSnapshotTransferState = WatchReliableSnapshotTransferState()
    private var recoveryState: WatchCommandRecoveryState?
    private var isConfigured = false
    private var isActivating = false
    private var isStopped = false

    init(
        projectStore: JSONProjectStore,
        entitlementCoordinator: EntitlementCoordinator,
        transport: any WatchConnectivityTransport,
        applicationSupportRoot: URL? = nil,
        languageCode: @escaping () -> String = {
            LanguageSettings().resolvedLanguage().rawValue
        },
        now: @escaping () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        observeCallbackGateState: @escaping @Sendable (AppSessionCallbackGate.State) -> Void = { _ in }
    ) {
        self.projectStore = projectStore
        self.entitlementCoordinator = entitlementCoordinator
        self.transport = transport
        let liveRoot = applicationSupportRoot ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnitNote", isDirectory: true)
        ledgerURL = WatchSyncPaths.processedLedger(in: liveRoot)
        preparedCommandURL = WatchSyncPaths.preparedCommand(in: liveRoot)
        self.languageCode = languageCode
        self.now = now
        self.sleep = sleep
        callbackGate = AppSessionCallbackGate(observeState: observeCallbackGateState)
    }

    func stopForSessionTransition() {
        guard !isStopped else { return }
        isStopped = true
        callbackGate.close()
        projectSubscription?.cancel()
        entitlementSubscription?.cancel()
        projectSubscription = nil
        entitlementSubscription = nil
        clearTransportCallbacks()
        stoppedTasks = [
            serialTask,
            activationRetryTask,
            reliableSnapshotRetryTask,
            entitlementExpiryTask,
        ].compactMap { $0 }
        stoppedTasks.forEach { $0.cancel() }
    }

    func waitForStoppedOperations() async throws {
        guard isStopped else {
            throw AppSessionProducerDrainError.producerStillActive
        }
        let callbackWaiter = Task { @MainActor [callbackGate] in
            try await callbackGate.waitUntilClosedAndIdle()
        }
        for task in stoppedTasks {
            await task.value
        }
        try await callbackWaiter.value
        try Task.checkCancellation()
    }

    func start() {
        guard !isStopped else { return }
        configureOnce()
        activate()
        publishLatestSnapshotIfChanged()
    }

    private func configureOnce() {
        guard !isConfigured else { return }
        isConfigured = true

        transport.onReceivedEnvelope = { [weak self] envelope, reply in
            _ = self?.enqueue(envelope, reply: reply)
        }
        transport.onActivationCompleted = { [weak self] activated, _ in
            guard let self, !isStopped else { return }
            isActivating = false
            if activated {
                activationRetryTask?.cancel()
                activationRetryTask = nil
                publishLatestSnapshotIfChanged()
            } else {
                scheduleActivationRetry()
            }
        }
        transport.onReachabilityChanged = { [weak self] reachable in
            guard let self, !isStopped, reachable else { return }
            self.publishLatestSnapshotIfChanged()
        }
        transport.onTransferCompleted = { [weak self] envelope, error in
            guard let self,
                  !isStopped,
                  error != nil,
                  case let .snapshot(snapshot)? = envelope,
                  reliableSnapshotTransferState.recordFailure(of: snapshot)
            else { return }
            scheduleReliableSnapshotRetry()
        }

        projectSubscription = projectStore.$projects
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, callbackGate] _ in
                guard let token = callbackGate.begin() else { return }
                Task { @MainActor [weak self] in
                    defer { callbackGate.finish(token) }
                    guard let self, !isStopped else { return }
                    publishLatestSnapshotIfChanged()
                }
            }

        entitlementSubscription = entitlementCoordinator.$snapshot
            .sink { [weak self, callbackGate] _ in
                guard let token = callbackGate.begin() else { return }
                Task { @MainActor [weak self] in
                    defer { callbackGate.finish(token) }
                    guard let self,
                          !isStopped,
                          self.entitlementCoordinator.verifiedSnapshot != nil
                    else { return }
                    self.scheduleEntitlementExpiryRefresh()
                    self.recoverPersistenceIfPossible()
                    self.publishLatestSnapshotIfChanged()
                }
            }

        recoverPersistenceIfPossible()
    }

    private func clearTransportCallbacks() {
        transport.onReceivedEnvelope = nil
        transport.onActivationCompleted = nil
        transport.onReachabilityChanged = nil
        transport.onTransferCompleted = nil
    }

    private func activate() {
        guard !isStopped, !isActivating else { return }
        isActivating = true
        transport.activate()
    }

    private func scheduleActivationRetry() {
        guard !isStopped, activationRetryTask == nil else { return }
        guard let token = callbackGate.begin() else { return }
        activationRetryToken = token
        let sleep = sleep
        activationRetryTask = Task { @MainActor [weak self, callbackGate] in
            defer { callbackGate.finish(token) }
            try? await sleep(.seconds(2))
            guard !Task.isCancelled, let self, !isStopped else { return }
            guard activationRetryToken == token else { return }
            activationRetryTask = nil
            activationRetryToken = nil
            activate()
        }
    }

    private func scheduleEntitlementExpiryRefresh() {
        guard !isStopped else { return }
        entitlementExpiryTask?.cancel()
        guard
            case let .trial(_, expiresAt)? = entitlementCoordinator.verifiedSnapshot,
            expiresAt > now()
        else { return }

        let delay = expiresAt.timeIntervalSince(now())
        guard let token = callbackGate.begin() else { return }
        entitlementExpiryToken = token
        let sleep = sleep
        entitlementExpiryTask = Task { @MainActor [weak self, callbackGate] in
            defer { callbackGate.finish(token) }
            try? await sleep(.seconds(delay))
            guard !Task.isCancelled, let self, !isStopped else { return }
            guard entitlementExpiryToken == token else { return }
            entitlementExpiryTask = nil
            entitlementExpiryToken = nil
            publishLatestSnapshotIfChanged()
            scheduleEntitlementExpiryRefresh()
        }
    }

    func publishLatestSnapshot() {
        guard !isStopped else { return }
        guard let snapshot = latestSnapshot() else { return }
        publish(snapshot)
    }

    func receive(_ envelope: WatchConnectivityEnvelope) async {
        guard let task = enqueue(envelope, reply: nil) else { return }
        await task.value
    }

    @discardableResult
    private func enqueue(
        _ envelope: WatchConnectivityEnvelope,
        reply: WatchConnectivityEnvelopeReply?
    ) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        let previous = serialTask
        let next = Task { @MainActor [weak self] in
            await previous.value
            guard let self, !isStopped else { return }
            handle(envelope, reply: reply)
        }
        serialTask = next
        return next
    }

    private func handle(
        _ envelope: WatchConnectivityEnvelope,
        reply: WatchConnectivityEnvelopeReply?
    ) {
        guard !isStopped else { return }
        switch envelope {
        case .snapshotRequest:
            sendSnapshot(reply: reply)
        case .snapshot:
            break
        case let .command(command):
            handle(command, reply: reply)
        case .acknowledgement:
            break
        case let .queueHandshake(commandIDs):
            handleQueueHandshake(commandIDs, reply: reply)
        }
    }

    private func handle(
        _ command: WatchCounterCommand,
        reply: WatchConnectivityEnvelopeReply?
    ) {
        guard !isStopped,
              let entitlement = entitlementCoordinator.verifiedSnapshot else {
            return
        }
        guard recoveryState != .requiresFreshHandshake else {
            // A snapshot reply is deliberately not an acknowledgement: the Watch
            // retains this command and includes its ID in the required handshake.
            sendSnapshot(reply: reply)
            return
        }

        do {
            let acknowledgement = withCurrentLanguage(
                try projectStore.applyWatchCommandDurably(
                    command,
                    entitlement: entitlement,
                    ledgerURL: ledgerURL,
                    preparedCommandURL: preparedCommandURL,
                    now: now()
                )
            )
            guard !isStopped else { return }
            recoveryState = .ready
            send(acknowledgement, reply: reply)
            publish(acknowledgement.snapshot)
        } catch WatchCommandPersistenceError.requiresFreshHandshake {
            recoveryState = .requiresFreshHandshake
            sendSnapshot(reply: reply)
        } catch ProjectStoreError.accessRestricted {
            do {
                let acknowledgement = withCurrentLanguage(
                    try projectStore.acknowledgeRejectedWatchCommandDurably(
                        command,
                        rejection: .entitlementRequired,
                        entitlement: entitlement,
                        ledgerURL: ledgerURL,
                        now: now()
                    )
                )
                guard !isStopped else { return }
                recoveryState = .ready
                send(acknowledgement, reply: reply)
                publish(acknowledgement.snapshot)
            } catch {
                recoveryState = nil
                sendSnapshot(reply: reply)
            }
        } catch {
            recoveryState = nil
            sendSnapshot(reply: reply)
        }
    }

    private func send(
        _ acknowledgement: WatchCommandAcknowledgement,
        reply: WatchConnectivityEnvelopeReply?
    ) {
        guard !isStopped else { return }
        let envelope = WatchConnectivityEnvelope.acknowledgement(acknowledgement)
        if let reply {
            reply(envelope)
        } else {
            transport.transferUserInfo(envelope)
        }
    }

    private func withCurrentLanguage(
        _ acknowledgement: WatchCommandAcknowledgement
    ) -> WatchCommandAcknowledgement {
        guard let snapshot = latestSnapshot() else { return acknowledgement }
        return WatchCommandAcknowledgement(
            commandID: acknowledgement.commandID,
            rejection: acknowledgement.rejection,
            snapshot: snapshot
        )
    }

    private func handleQueueHandshake(
        _ commandIDs: [UUID],
        reply: WatchConnectivityEnvelopeReply?
    ) {
        guard !isStopped,
              let entitlement = entitlementCoordinator.verifiedSnapshot else { return }
        do {
            recoveryState = try projectStore.recoverWatchCommandPersistence(
                entitlement: entitlement,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedCommandURL,
                now: now()
            )
            guard !isStopped else { return }
            if recoveryState == .requiresFreshHandshake {
                recoveryState = try projectStore.reconcileWatchQueueHandshakeDurably(
                    queuedCommandIDs: commandIDs,
                    entitlement: entitlement,
                    ledgerURL: ledgerURL,
                    preparedCommandURL: preparedCommandURL,
                    now: now()
                )
                guard !isStopped else { return }
            }
        } catch {
            recoveryState = nil
        }
        sendSnapshot(reply: reply)
    }

    private func sendSnapshot(reply: WatchConnectivityEnvelopeReply?) {
        guard !isStopped else { return }
        guard let snapshot = latestSnapshot() else { return }
        let envelope = WatchConnectivityEnvelope.snapshot(snapshot)
        if let reply {
            reply(envelope)
        }
        publish(snapshot)
    }

    func publishLatestSnapshotIfChanged() {
        guard !isStopped else { return }
        guard let snapshot = latestSnapshot() else { return }
        if snapshot.projects != lastPublishedProjects
            || snapshot.entitlement != lastPublishedEntitlement
            || snapshot.languageCode != lastPublishedLanguageCode {
            publish(snapshot)
        } else {
            queueReliableSnapshotIfNeeded(snapshot)
        }
    }

    private func publish(_ snapshot: WatchSyncSnapshot) {
        guard !isStopped else { return }
        do {
            try transport.updateApplicationContext(.snapshot(snapshot))
            guard !isStopped else { return }
            lastPublishedProjects = snapshot.projects
            lastPublishedEntitlement = snapshot.entitlement
            lastPublishedLanguageCode = snapshot.languageCode
        } catch {
            // Leave the marker unchanged so start, reachability, or the next
            // project event retries this exact authoritative payload.
        }

        queueReliableSnapshotIfNeeded(snapshot)
    }

    private func queueReliableSnapshotIfNeeded(_ snapshot: WatchSyncSnapshot) {
        guard !isStopped else { return }
        guard reliableSnapshotTransferState.prepareTransfer(of: snapshot) else { return }
        guard !isStopped else { return }
        transport.transferUserInfo(.snapshot(snapshot))
    }

    private func scheduleReliableSnapshotRetry() {
        guard !isStopped, reliableSnapshotRetryTask == nil else { return }
        guard let token = callbackGate.begin() else { return }
        reliableSnapshotRetryToken = token
        let sleep = sleep
        reliableSnapshotRetryTask = Task { @MainActor [weak self, callbackGate] in
            defer { callbackGate.finish(token) }
            try? await sleep(.seconds(2))
            guard !Task.isCancelled, let self, !isStopped else { return }
            guard reliableSnapshotRetryToken == token else { return }
            reliableSnapshotRetryTask = nil
            reliableSnapshotRetryToken = nil
            guard let snapshot = latestSnapshot() else { return }
            queueReliableSnapshotIfNeeded(snapshot)
        }
    }

    private func latestSnapshot() -> WatchSyncSnapshot? {
        guard !isStopped,
              let entitlement = entitlementCoordinator.verifiedSnapshot else {
            return nil
        }
        let languageCode = languageCode()
        do {
            return try WatchSnapshotBuilder.make(
                projects: projectStore.projects,
                entitlement: entitlement,
                locale: Locale(identifier: languageCode),
                languageCode: languageCode,
                generatedAt: now()
            )
        } catch {
            return WatchSyncSnapshot(
                generatedAt: now(),
                entitlement: WatchEntitlementSnapshot(
                    kind: .trialNotStarted,
                    expiresAt: nil,
                    generatedAt: now()
                ),
                projects: [],
                languageCode: languageCode
            )
        }
    }

    private func recoverPersistenceIfPossible() {
        guard !isStopped,
              let entitlement = entitlementCoordinator.verifiedSnapshot else { return }
        do {
            recoveryState = try projectStore.recoverWatchCommandPersistence(
                entitlement: entitlement,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedCommandURL,
                now: now()
            )
        } catch {
            recoveryState = nil
        }
    }
}
