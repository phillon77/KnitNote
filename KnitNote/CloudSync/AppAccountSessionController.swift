import Combine
import Foundation

/// Serializes confirmed identity requests and the existing account transaction.
/// This injectable runtime does not construct any system service or observer.
@MainActor final class AppAccountSessionController: ObservableObject {
    enum State: Equatable {
        case idle, checking, noAccount, unknown, opening, localReady, bootstrapRequired, blocked
    }
    @Published private(set) var state: State = .idle
    private var desiredState: State = .idle
    private var projectingState = false
    private let query: CloudAccountIdentityQuery
    private let lifecycle: AppAccountDomainLifecycle
    private let coordinator: CloudAccountTransitionCoordinator
    private let now: () -> Date
    private var started = false
    private var stopped = false
    private var requestGeneration: UInt64 = 0
    private var pendingQuery = false
    private var pendingSync = false
    private var acceptedGeneration: UInt64?
    private var pump: Task<Void, Never>?
    private var shutdown: Task<Bool, Never>?

    init(query: CloudAccountIdentityQuery, lifecycle: AppAccountDomainLifecycle,
         coordinator: CloudAccountTransitionCoordinator, now: @escaping () -> Date) {
        self.query = query; self.lifecycle = lifecycle
        self.coordinator = coordinator; self.now = now
        coordinator.accountInvalidatedHandler = { [weak self] in self?.accountDidChange() }
        coordinator.statusDidChangeHandler = { [weak self] in self?.projectCoordinatorState() }
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        requestIdentity()
    }

    func accountDidChange() {
        guard !stopped else { return }
        started = true
        requestIdentity()
    }

    func retry() {
        guard !stopped else { return }
        if !started { start(); return }
        // An active request already represents this retry. Only an authoritative
        // event may supersede it and require another query.
        if pump != nil {
            if desiredState == .unknown || desiredState == .bootstrapRequired || desiredState == .blocked {
                requestIdentity()
            }
            return
        }
        if acceptedGeneration == requestGeneration && coordinator.localAccessReady {
            pendingSync = true; ensurePump()
        } else { requestIdentity() }
    }

    func foreground() { retry() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        requestGeneration &+= 1
        acceptedGeneration = nil; pendingQuery = false; pendingSync = false
        _ = lifecycle.beginTransition()
        coordinator.stopForAccountTransition()
        setState(.idle)
        // Cancellation of a waiter cannot cancel or skip the actual drain.
        // Capture only the owned work/dependencies, not the controller.
        shutdown = Task { @MainActor [pump, coordinator, lifecycle] in
            await pump?.value
            await coordinator.waitForStoppedOperations()
            do { try await lifecycle.waitForStoppedOperations(); return true }
            catch { return false }
        }
    }

    func waitUntilStopped() async {
        stop()
        if await shutdown?.value == false { setState(.blocked) }
    }

    private func requestIdentity() {
        requestGeneration &+= 1
        let requested = requestGeneration
        acceptedGeneration = nil; pendingQuery = true; pendingSync = false
        _ = lifecycle.beginTransition()
        guard !stopped, requestGeneration == requested else { return }
        coordinator.stopForAccountTransition()
        guard !stopped, requestGeneration == requested else { return }
        setState(.checking)
        guard !stopped, requestGeneration == requested else { return }
        ensurePump()
    }

    private func ensurePump() {
        guard pump == nil else { return }
        // The pump has no idle event stream: it releases the controller when the
        // finite set of requested work settles, including after stop.
        pump = Task { @MainActor [weak self] in await self?.runPump() }
    }

    private func runPump() async {
        defer { pump = nil }
        while !stopped {
            if pendingQuery {
                pendingQuery = false
                let generation = requestGeneration
                let result = await query.query()
                guard !stopped, generation == requestGeneration else { continue }
                switch result {
                case .unknown:
                    setState(.unknown)
                case .confirmed(let account):
                    acceptedGeneration = generation
                    setState(.opening)
                    guard !stopped, generation == requestGeneration else { continue }
                    do { try await coordinator.reconcileConfirmedAccount(account, now: now()) }
                    catch { /* Actual retained state determines the projection and next retry. */ }
                    guard !stopped, generation == requestGeneration else { continue }
                    projectCoordinatorState()
                case .noAccount:
                    acceptedGeneration = generation
                    setState(.opening)
                    guard !stopped, generation == requestGeneration else { continue }
                    do {
                        try await coordinator.reconcileConfirmedAccount(nil, now: now())
                        guard !stopped, generation == requestGeneration else { continue }
                        setState(.noAccount)
                    } catch {
                        guard !stopped, generation == requestGeneration else { continue }
                        setState(.blocked)
                    }
                }
            } else if pendingSync {
                pendingSync = false
                await coordinator.retrySync()
                projectCoordinatorState()
            } else { return }
        }
    }

    private func projectCoordinatorState() {
        guard !stopped, acceptedGeneration == requestGeneration else { return }
        if coordinator.localAccessReady { setState(.localReady) }
        else if coordinator.requiresBootstrap { setState(.bootstrapRequired) }
        else if coordinator.phase == .blocked { setState(.blocked) }
    }

    private func setState(_ next: State) {
        desiredState = next
        guard !projectingState else { return }
        projectingState = true
        defer { projectingState = false }
        // @Published calls observers before storing. A nested stop/event owns
        // the desired state and must survive the outer assignment returning.
        while state != desiredState { state = desiredState }
    }
}
