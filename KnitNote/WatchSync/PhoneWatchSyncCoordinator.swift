#if os(iOS)
import Combine
import Foundation

@MainActor
final class PhoneWatchSyncCoordinator: ObservableObject {
    private let projectStore: JSONProjectStore
    private let entitlementCoordinator: EntitlementCoordinator
    private let transport: any WatchConnectivityTransport
    private let ledgerURL: URL
    private let preparedCommandURL: URL
    private let locale: () -> Locale
    private let now: () -> Date

    private var projectSubscription: AnyCancellable?
    private var entitlementSubscription: AnyCancellable?
    private var serialTask: Task<Void, Never> = Task {}
    private var activationRetryTask: Task<Void, Never>?
    private var reliableSnapshotRetryTask: Task<Void, Never>?
    private var entitlementExpiryTask: Task<Void, Never>?
    private var lastPublishedProjects: [WatchProjectSnapshot]?
    private var lastPublishedEntitlement: WatchEntitlementSnapshot?
    private var reliableSnapshotTransferState = WatchReliableSnapshotTransferState()
    private var recoveryState: WatchCommandRecoveryState?
    private var isConfigured = false
    private var isActivating = false

    init(
        projectStore: JSONProjectStore,
        entitlementCoordinator: EntitlementCoordinator,
        transport: (any WatchConnectivityTransport)? = nil,
        applicationSupportRoot: URL? = nil,
        locale: @escaping () -> Locale = { .current },
        now: @escaping () -> Date = { .now }
    ) {
        self.projectStore = projectStore
        self.entitlementCoordinator = entitlementCoordinator
        self.transport = transport ?? PhoneWatchSession()
        let liveRoot = applicationSupportRoot ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnitNote", isDirectory: true)
        ledgerURL = WatchSyncPaths.processedLedger(in: liveRoot)
        preparedCommandURL = WatchSyncPaths.preparedCommand(in: liveRoot)
        self.locale = locale
        self.now = now
    }

    func start() {
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
            guard let self else { return }
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
            guard reachable else { return }
            self?.publishLatestSnapshotIfChanged()
        }
        transport.onTransferCompleted = { [weak self] envelope, error in
            guard let self,
                  error != nil,
                  case let .snapshot(snapshot)? = envelope,
                  reliableSnapshotTransferState.recordFailure(of: snapshot)
            else { return }
            scheduleReliableSnapshotRetry()
        }

        projectSubscription = projectStore.$projects
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.publishLatestSnapshotIfChanged()
                }
            }

        entitlementSubscription = entitlementCoordinator.$snapshot
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.entitlementCoordinator.verifiedSnapshot != nil
                    else { return }
                    self.scheduleEntitlementExpiryRefresh()
                    self.recoverPersistenceIfPossible()
                    self.publishLatestSnapshotIfChanged()
                }
            }

        recoverPersistenceIfPossible()
    }

    private func activate() {
        guard !isActivating else { return }
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

    private func scheduleEntitlementExpiryRefresh() {
        entitlementExpiryTask?.cancel()
        entitlementExpiryTask = nil
        guard
            case let .trial(_, expiresAt)? = entitlementCoordinator.verifiedSnapshot,
            expiresAt > now()
        else { return }

        let delay = expiresAt.timeIntervalSince(now())
        entitlementExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            entitlementExpiryTask = nil
            publishLatestSnapshotIfChanged()
            scheduleEntitlementExpiryRefresh()
        }
    }

    func publishLatestSnapshot() {
        guard let snapshot = latestSnapshot() else { return }
        publish(snapshot)
    }

    func receive(_ envelope: WatchConnectivityEnvelope) async {
        await enqueue(envelope, reply: nil).value
    }

    @discardableResult
    private func enqueue(
        _ envelope: WatchConnectivityEnvelope,
        reply: WatchConnectivityEnvelopeReply?
    ) -> Task<Void, Never> {
        let previous = serialTask
        let next = Task { @MainActor [weak self] in
            await previous.value
            guard let self else { return }
            handle(envelope, reply: reply)
        }
        serialTask = next
        return next
    }

    private func handle(
        _ envelope: WatchConnectivityEnvelope,
        reply: WatchConnectivityEnvelopeReply?
    ) {
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
        guard let entitlement = entitlementCoordinator.verifiedSnapshot else {
            return
        }
        guard recoveryState != .requiresFreshHandshake else {
            // A snapshot reply is deliberately not an acknowledgement: the Watch
            // retains this command and includes its ID in the required handshake.
            sendSnapshot(reply: reply)
            return
        }

        do {
            let acknowledgement = try projectStore.applyWatchCommandDurably(
                command,
                entitlement: entitlement,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedCommandURL,
                now: now()
            )
            recoveryState = .ready
            send(acknowledgement, reply: reply)
            publish(acknowledgement.snapshot)
        } catch WatchCommandPersistenceError.requiresFreshHandshake {
            recoveryState = .requiresFreshHandshake
            sendSnapshot(reply: reply)
        } catch ProjectStoreError.accessRestricted {
            do {
                let acknowledgement = try projectStore.acknowledgeRejectedWatchCommandDurably(
                    command,
                    rejection: .entitlementRequired,
                    entitlement: entitlement,
                    ledgerURL: ledgerURL,
                    now: now()
                )
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
        let envelope = WatchConnectivityEnvelope.acknowledgement(acknowledgement)
        if let reply {
            reply(envelope)
        } else {
            transport.transferUserInfo(envelope)
        }
    }

    private func handleQueueHandshake(
        _ commandIDs: [UUID],
        reply: WatchConnectivityEnvelopeReply?
    ) {
        guard let entitlement = entitlementCoordinator.verifiedSnapshot else { return }
        do {
            recoveryState = try projectStore.recoverWatchCommandPersistence(
                entitlement: entitlement,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedCommandURL,
                now: now()
            )
            if recoveryState == .requiresFreshHandshake {
                recoveryState = try projectStore.reconcileWatchQueueHandshakeDurably(
                    queuedCommandIDs: commandIDs,
                    entitlement: entitlement,
                    ledgerURL: ledgerURL,
                    preparedCommandURL: preparedCommandURL,
                    now: now()
                )
            }
        } catch {
            recoveryState = nil
        }
        sendSnapshot(reply: reply)
    }

    private func sendSnapshot(reply: WatchConnectivityEnvelopeReply?) {
        guard let snapshot = latestSnapshot() else { return }
        let envelope = WatchConnectivityEnvelope.snapshot(snapshot)
        if let reply {
            reply(envelope)
        }
        publish(snapshot)
    }

    private func publishLatestSnapshotIfChanged() {
        guard let snapshot = latestSnapshot() else { return }
        if snapshot.projects != lastPublishedProjects
            || snapshot.entitlement != lastPublishedEntitlement {
            publish(snapshot)
        } else {
            queueReliableSnapshotIfNeeded(snapshot)
        }
    }

    private func publish(_ snapshot: WatchSyncSnapshot) {
        do {
            try transport.updateApplicationContext(.snapshot(snapshot))
            lastPublishedProjects = snapshot.projects
            lastPublishedEntitlement = snapshot.entitlement
        } catch {
            // Leave the marker unchanged so start, reachability, or the next
            // project event retries this exact authoritative payload.
        }

        queueReliableSnapshotIfNeeded(snapshot)
    }

    private func queueReliableSnapshotIfNeeded(_ snapshot: WatchSyncSnapshot) {
        guard reliableSnapshotTransferState.prepareTransfer(of: snapshot) else { return }
        transport.transferUserInfo(.snapshot(snapshot))
    }

    private func scheduleReliableSnapshotRetry() {
        guard reliableSnapshotRetryTask == nil else { return }
        reliableSnapshotRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            reliableSnapshotRetryTask = nil
            guard let snapshot = latestSnapshot() else { return }
            queueReliableSnapshotIfNeeded(snapshot)
        }
    }

    private func latestSnapshot() -> WatchSyncSnapshot? {
        guard let entitlement = entitlementCoordinator.verifiedSnapshot else {
            return nil
        }
        do {
            return try WatchSnapshotBuilder.make(
                projects: projectStore.projects,
                entitlement: entitlement,
                locale: locale(),
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
                projects: []
            )
        }
    }

    private func recoverPersistenceIfPossible() {
        guard let entitlement = entitlementCoordinator.verifiedSnapshot else { return }
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
#endif
