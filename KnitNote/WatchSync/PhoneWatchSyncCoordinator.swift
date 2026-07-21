#if os(iOS)
import Combine
import Foundation

@MainActor
final class PhoneWatchSyncCoordinator: ObservableObject {
    private let projectStore: JSONProjectStore
    private let transport: any WatchConnectivityTransport
    private let ledgerURL: URL
    private let preparedCommandURL: URL
    private let locale: () -> Locale
    private let now: () -> Date

    private var projectSubscription: AnyCancellable?
    private var serialTask: Task<Void, Never> = Task {}
    private var activationRetryTask: Task<Void, Never>?
    private var lastPublishedProjects: [WatchProjectSnapshot]?
    private var recoveryState: WatchCommandRecoveryState?
    private var isConfigured = false
    private var isActivating = false

    init(
        projectStore: JSONProjectStore,
        transport: (any WatchConnectivityTransport)? = nil,
        applicationSupportRoot: URL? = nil,
        locale: @escaping () -> Locale = { .current },
        now: @escaping () -> Date = { .now }
    ) {
        self.projectStore = projectStore
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

        projectSubscription = projectStore.$projects
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.publishLatestSnapshotIfChanged()
                }
            }

        do {
            recoveryState = try projectStore.recoverWatchCommandPersistence(
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedCommandURL,
                now: now()
            )
        } catch {
            recoveryState = nil
        }
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

    func publishLatestSnapshot() {
        publish(latestSnapshot())
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
        guard recoveryState != .requiresFreshHandshake else {
            // A snapshot reply is deliberately not an acknowledgement: the Watch
            // retains this command and includes its ID in the required handshake.
            sendSnapshot(reply: reply)
            return
        }

        do {
            let acknowledgement = try projectStore.applyWatchCommandDurably(
                command,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedCommandURL,
                now: now()
            )
            recoveryState = .ready
            let envelope = WatchConnectivityEnvelope.acknowledgement(acknowledgement)
            if let reply {
                reply(envelope)
            } else {
                transport.transferUserInfo(envelope)
            }
            publish(acknowledgement.snapshot)
        } catch WatchCommandPersistenceError.requiresFreshHandshake {
            recoveryState = .requiresFreshHandshake
            sendSnapshot(reply: reply)
        } catch {
            recoveryState = nil
            sendSnapshot(reply: reply)
        }
    }

    private func handleQueueHandshake(
        _ commandIDs: [UUID],
        reply: WatchConnectivityEnvelopeReply?
    ) {
        do {
            recoveryState = try projectStore.recoverWatchCommandPersistence(
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedCommandURL,
                now: now()
            )
            if recoveryState == .requiresFreshHandshake {
                recoveryState = try projectStore.reconcileWatchQueueHandshakeDurably(
                    queuedCommandIDs: commandIDs,
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
        let snapshot = latestSnapshot()
        let envelope = WatchConnectivityEnvelope.snapshot(snapshot)
        if let reply {
            reply(envelope)
        } else {
            transport.transferUserInfo(envelope)
        }
        publish(snapshot)
    }

    private func publishLatestSnapshotIfChanged() {
        let snapshot = latestSnapshot()
        guard snapshot.projects != lastPublishedProjects else { return }
        publish(snapshot)
    }

    private func publish(_ snapshot: WatchSyncSnapshot) {
        do {
            try transport.updateApplicationContext(.snapshot(snapshot))
            lastPublishedProjects = snapshot.projects
        } catch {
            // Leave the marker unchanged so start, reachability, or the next
            // project event retries this exact authoritative payload.
        }
    }

    private func latestSnapshot() -> WatchSyncSnapshot {
        do {
            return try WatchSnapshotBuilder.make(
                projects: projectStore.projects,
                locale: locale(),
                generatedAt: now()
            )
        } catch {
            return WatchSyncSnapshot(generatedAt: now(), projects: [])
        }
    }
}
#endif
