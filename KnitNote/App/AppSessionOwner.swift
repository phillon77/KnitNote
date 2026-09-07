import Combine
import Foundation

@MainActor
/// Owns local publication and retirement only. A generation is not evidence
/// of account identity, cloud readiness, durable health, or cleanup authority.
final class AppSessionOwner: ObservableObject {
    enum Failure: Error, Equatable {
        case staleGeneration
        case retiredWorkPending
        case stoppedSession
        case sessionAlreadyVisible
    }

    @Published private(set) var visibleSession: AppSessionResources?
    private(set) var generation = UUID()
    private var committedSession: AppSessionResources?
    private var retiredSessions: [AppSessionResources] = []
    private var boundaryDepth = 0
    private var isProjecting = false

    /// Invalidates synchronously, before any caller can begin async transition work.
    /// Reentrant transitions each receive their own token; an outer token can
    /// already be stale when this method returns.
    func beginTransition() -> UUID {
        boundaryDepth += 1
        defer { boundaryDepth -= 1 }
        let next = UUID()
        generation = next
        let old = committedSession
        committedSession = nil
        if let old, !retiredSessions.contains(where: { $0 === old }) {
            retiredSessions.append(old)
        }
        projectCommittedSession()
        old?.stopForSessionTransition()
        projectCommittedSession()
        return next
    }

    /// Keeps failed/cancelled work retained. Other waiters may finish the same
    /// entry and retire a newer session while this waiter is suspended.
    func waitForRetiredSessions() async throws {
        try Task.checkCancellation()
        while let retired = retiredSessions.first {
            try await retired.waitForStoppedOperations()
            try Task.checkCancellation()
            retiredSessions.removeAll { $0 === retired }
        }
    }

    /// Ownership transfers only on success. Rejected prepared candidates stay
    /// with the caller and are never stopped here. This local gate does not
    /// establish the account/readiness authority required by future App wiring.
    func publishPreparedSession(_ candidate: AppSessionResources, for requestedGeneration: UUID) throws {
        try validate(candidate, for: requestedGeneration)
        if let committedSession {
            guard committedSession === candidate else { throw Failure.sessionAlreadyVisible }
            return
        }
        boundaryDepth += 1
        defer { boundaryDepth -= 1 }

        // @Published invokes subscribers before storing the new value. During
        // that callout a transition may invalidate this offer. Do not accept
        // candidate ownership until the setter and its subscribers return.
        isProjecting = true
        visibleSession = candidate
        isProjecting = false
        do {
            try validate(candidate, for: requestedGeneration, insidePublication: true)
            committedSession = candidate
        } catch {
            projectCommittedSession()
            throw error
        }
    }

    private func validate(
        _ candidate: AppSessionResources,
        for requestedGeneration: UUID,
        insidePublication: Bool = false
    ) throws {
        guard requestedGeneration == generation else { throw Failure.staleGeneration }
        // Covers half-complete stop and @Published callouts as well as async drain.
        guard (boundaryDepth == 0 || insidePublication), retiredSessions.isEmpty else {
            throw Failure.retiredWorkPending
        }
        guard !candidate.isStopped, !candidate.store.isSessionWriteRevoked else { throw Failure.stoppedSession }
    }

    private func projectCommittedSession() {
        guard !isProjecting else { return }
        isProjecting = true
        defer { isProjecting = false }
        // A nested transition changes committed state but cannot nest a
        // willSet assignment. Reconcile after every subscriber callout.
        while visibleSession !== committedSession {
            visibleSession = committedSession
        }
    }
}
