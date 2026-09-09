import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct LegacyImportPreparationCoordinatorTests {
    @Test func preparationRequiresSeparateSingleUseConfirmation() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let before = try fixture.service.observeLegacyImportSource()
        let coordinator = LegacyImportPreparationCoordinator(service: fixture.service)
        let context = preparationContext()

        let proposal = try await coordinator.prepare(context: context)
        let package = try #require(fixture.packages().first)
        #expect(try Data(contentsOf: package.appendingPathComponent("Data/projects-v1.json")) == fixture.bytes)
        #expect(try fixture.service.observeLegacyImportSource() == before)
        #expect(try await coordinator.confirm(proposal, context: context))
        #expect(try await coordinator.confirm(proposal, context: context) == false)
        await coordinator.stopAndDrain()
        #expect(try fixture.packages() == [package])
    }

    @Test func revokedPreparationCannotConfirm() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let coordinator = LegacyImportPreparationCoordinator(service: fixture.service)
        let context = preparationContext()
        let proposal = try await coordinator.prepare(context: context)
        coordinator.invalidate()
        #expect(try await coordinator.confirm(proposal, context: context) == false)
        await coordinator.stopAndDrain()
        #expect(try fixture.packages().count == 1)
    }

    @Test func ineligibleContextNeverStartsBackup() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let coordinator = LegacyImportPreparationCoordinator(service: fixture.service)
        var contexts = LegacyLocalImportSource.allCases.filter { $0 != .availableLocalHistoryUnknown }
            .map { preparationContext(source: $0) }
        contexts += [0, 31, 33].map { preparationContext(accountDigest: Data(repeating: 1, count: $0)) }
        for context in contexts {
            await #expect(throws: KnitNoteBackupError.accessDenied) {
                _ = try await coordinator.prepare(context: context)
            }
        }
        coordinator.invalidate()
        await coordinator.stopAndDrain()
        #expect(!FileManager.default.fileExists(atPath: fixture.service.workRoot.path))
        #expect(try Data(contentsOf: fixture.archiveURL) == fixture.bytes)
    }

    @Test func originalArchiveChangeRejectsAndRevokesProposalWithoutDeletingBackup() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let coordinator = LegacyImportPreparationCoordinator(service: fixture.service)
        let context = preparationContext()
        let proposal = try await coordinator.prepare(context: context)
        let package = try #require(fixture.packages().first)
        try (fixture.bytes + Data([0x20])).write(to: fixture.archiveURL)

        await #expect(throws: KnitNoteBackupError.integrityMismatch("projects-v1.json")) {
            try await coordinator.confirm(proposal, context: context)
        }
        try fixture.bytes.write(to: fixture.archiveURL)
        #expect(try await coordinator.confirm(proposal, context: context) == false)
        #expect(try Data(contentsOf: package.appendingPathComponent("Data/projects-v1.json")) == fixture.bytes)
        _ = try fixture.service.inspectPackage(at: package)
    }

    @Test func unreadableSourceRevokesCurrentProposalBeforeRethrowing() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let coordinator = LegacyImportPreparationCoordinator(service: fixture.service)
        let context = preparationContext()
        let proposal = try await coordinator.prepare(context: context)
        try FileManager.default.removeItem(at: fixture.archiveURL)
        await #expect(throws: (any Error).self) { try await coordinator.confirm(proposal, context: context) }
        try fixture.bytes.write(to: fixture.archiveURL)
        #expect(try await coordinator.confirm(proposal, context: context) == false)
        #expect(try fixture.packages().count == 1)
    }

    @Test func tamperedPreparedArchiveRevokesAndRetainsPackage() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let coordinator = LegacyImportPreparationCoordinator(service: fixture.service)
        let context = preparationContext()
        let proposal = try await coordinator.prepare(context: context)
        let package = try #require(fixture.packages().first)
        let copiedArchive = package.appendingPathComponent("Data/projects-v1.json")
        try (fixture.bytes + Data([0x20])).write(to: copiedArchive)
        await #expect(throws: (any Error).self) { try await coordinator.confirm(proposal, context: context) }
        try fixture.bytes.write(to: copiedArchive)
        #expect(try await coordinator.confirm(proposal, context: context) == false)
        #expect(try fixture.packages() == [package])
        #expect(try Data(contentsOf: fixture.archiveURL) == fixture.bytes)
    }

    @Test func wrongAndCrossOwnerProposalsLeaveNewPendingProposalUsable() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let coordinator = LegacyImportPreparationCoordinator(service: fixture.service)
        let other = LegacyImportPreparationCoordinator(service: fixture.service)
        let context = preparationContext()
        let old = try await coordinator.prepare(context: context)
        let current = try await coordinator.prepare(context: context)
        let foreign = try await other.prepare(context: context)
        #expect(try await coordinator.confirm(old, context: context) == false)
        #expect(try await coordinator.confirm(foreign, context: context) == false)
        #expect(try await coordinator.confirm(current, context: context))
        #expect(try await other.confirm(foreign, context: context))
    }

    @Test func contextMismatchRevokesEvenIfOriginalContextIsRestored() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let coordinator = LegacyImportPreparationCoordinator(service: fixture.service)
        let context = preparationContext()
        for change in 0..<4 {
            let proposal = try await coordinator.prepare(context: context)
            var changed = context
            switch change {
            case 0: changed.accountDigest = Data(repeating: 2, count: 32)
            case 1: changed.sourceSession = UUID()
            case 2: changed.targetSession = UUID()
            default: changed.source = .accountUnknown
            }
            #expect(try await coordinator.confirm(proposal, context: changed) == false)
            #expect(try await coordinator.confirm(proposal, context: context) == false)
        }
    }

    @Test func cancellationDuringCopyKeepsDrainAndBlocksRetryUntilNativeCompletion() async throws {
        let photoBytes = Data(repeating: 0x47, count: 70_000)
        let fixture = try sourceFixture(photoBytes: photoBytes)
        defer { fixture.remove() }
        let photoURL = try #require(fixture.photoURL)
        // Two source-observation chunks precede the first actual backup-copy chunk.
        let barrier = NativePreparationBarrier(blockOnHit: 3)
        defer { barrier.release() }
        let service = KnitNoteBackupService(liveRoot: fixture.service.liveRoot, workRoot: fixture.service.workRoot,
            copyChunkHook: { url, _ in if url == photoURL { barrier.block() } })
        let coordinator = LegacyImportPreparationCoordinator(service: service)
        let context = preparationContext()
        var returnedProposal: LegacyLocalImportConsentModel.Proposal?
        var wasCancelled = false
        let operation = Task { @MainActor in
            do { returnedProposal = try await coordinator.prepare(context: context) }
            catch is CancellationError { wasCancelled = true }
            catch { Issue.record("Unexpected preparation error: \(error)") }
        }
        await barrier.waitUntilBlocked()
        let partialCopy = Result {
            let package = try #require(fixture.packages().first)
            let temporary = try #require(FileManager.default.contentsOfDirectory(
                at: package.appendingPathComponent("Data/ProjectPhotos"), includingPropertiesForKeys: nil
            ).first)
            return try Data(contentsOf: temporary).count
        }
        operation.cancel()
        coordinator.invalidate()
        let drainStarted = PreparationSignal()
        var drained = false
        let drain = Task { @MainActor in
            drainStarted.signal()
            await coordinator.stopAndDrain()
            drained = true
        }
        await drainStarted.wait()
        await #expect(throws: KnitNoteBackupError.operationInProgress) {
            _ = try await coordinator.prepare(context: context)
        }
        #expect(!drained)
        barrier.release()
        await drain.value
        await operation.value
        #expect(drained && wasCancelled)
        #expect(returnedProposal == nil)
        #expect(try partialCopy.get() == 65_536)
        let package = try #require(fixture.packages().first)
        let copiedPhoto = package.appendingPathComponent("Data/ProjectPhotos/\(photoURL.lastPathComponent)")
        _ = try fixture.service.inspectPackage(at: package)
        #expect(try Data(contentsOf: fixture.archiveURL) == fixture.bytes)
        #expect(try Data(contentsOf: copiedPhoto) == photoBytes)
        #expect(try Data(contentsOf: photoURL) == photoBytes)
        let retry = try await coordinator.prepare(context: context)
        #expect(try await coordinator.confirm(retry, context: context))
        #expect(try fixture.packages().count == 2)
    }

    @Test func callerCancellationAfterBackupDoesNotPresentLateResult() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let barrier = NativePreparationBarrier()
        defer { barrier.release() }
        let service = KnitNoteBackupService(liveRoot: fixture.service.liveRoot, workRoot: fixture.service.workRoot,
            legacyImportPreparationStepHook: { step in
                if case .afterBackupObservation = step { barrier.block() }
            })
        let coordinator = LegacyImportPreparationCoordinator(service: service)
        let context = preparationContext()
        var wasCancelled = false
        let operation = Task { @MainActor in
            do {
                _ = try await coordinator.prepare(context: context)
                Issue.record("Cancelled preparation returned a proposal")
            } catch is CancellationError { wasCancelled = true }
            catch { Issue.record("Unexpected preparation error: \(error)") }
        }
        await barrier.waitUntilBlocked()
        operation.cancel()
        // No explicit invalidation: caller cancellation is checked on MainActor after the native await.
        barrier.release()
        await operation.value
        #expect(wasCancelled)
        let package = try #require(fixture.packages().first)
        _ = try fixture.service.inspectPackage(at: package)
        #expect(try Data(contentsOf: fixture.archiveURL) == fixture.bytes)
        await coordinator.stopAndDrain()
    }

    @Test func invalidatedPreparationStillReturnsNativeReadFailureAndAllowsRetry() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let barrier = NativePreparationBarrier()
        defer { barrier.release() }
        let service = KnitNoteBackupService(liveRoot: fixture.service.liveRoot, workRoot: fixture.service.workRoot,
            legacyImportPreparationStepHook: { step in
                if case .afterBackupObservation = step { barrier.block() }
            })
        let coordinator = LegacyImportPreparationCoordinator(service: service)
        let context = preparationContext()
        var nativeError: KnitNoteBackupError?
        let operation = Task { @MainActor in
            do {
                _ = try await coordinator.prepare(context: context)
                Issue.record("Invalid source unexpectedly produced a proposal")
            } catch { nativeError = error as? KnitNoteBackupError }
        }
        await barrier.waitUntilBlocked()
        let mutation = Result { try Data("invalid archive".utf8).write(to: fixture.archiveURL) }
        coordinator.invalidate()
        barrier.release()
        await operation.value
        try mutation.get()
        #expect(nativeError == .invalidArchive)
        let package = try #require(fixture.packages().first)
        _ = try fixture.service.inspectPackage(at: package)
        try fixture.bytes.write(to: fixture.archiveURL)
        let retry = try await coordinator.prepare(context: context)
        #expect(try await coordinator.confirm(retry, context: context))
    }

    @Test func accountABAWhileRevalidatingCannotConfirmAndBusyDoesNotDisturbOwner() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let barrier = NativePreparationBarrier(blockOnHit: 2)
        defer { barrier.release() }
        let service = KnitNoteBackupService(liveRoot: fixture.service.liveRoot, workRoot: fixture.service.workRoot,
            beforeLegacyImportPackageFinalPathValidation: { _ in barrier.block() })
        let coordinator = LegacyImportPreparationCoordinator(service: service)
        let context = preparationContext()
        let proposal = try await coordinator.prepare(context: context)
        var confirmed = true
        let operation = Task { @MainActor in
            do { confirmed = try await coordinator.confirm(proposal, context: context) }
            catch { Issue.record("Unexpected confirmation error: \(error)") }
        }
        await barrier.waitUntilBlocked()
        await #expect(throws: KnitNoteBackupError.operationInProgress) {
            _ = try await coordinator.prepare(context: preparationContext())
        }
        coordinator.invalidate() // Account A -> B.
        coordinator.invalidate() // Account B -> A; final context equality alone is insufficient.
        barrier.release()
        await operation.value
        #expect(!confirmed)
        #expect(try await coordinator.confirm(proposal, context: context) == false)
        let retry = try await coordinator.prepare(context: context)
        #expect(try await coordinator.confirm(proposal, context: context) == false)
        #expect(try await coordinator.confirm(retry, context: context))
    }

    @Test func busyPrepareAndConfirmDoNotRevokeActiveConfirmation() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let barrier = NativePreparationBarrier(blockOnHit: 2)
        defer { barrier.release() }
        let service = KnitNoteBackupService(liveRoot: fixture.service.liveRoot, workRoot: fixture.service.workRoot,
            beforeLegacyImportPackageFinalPathValidation: { _ in barrier.block() })
        let coordinator = LegacyImportPreparationCoordinator(service: service)
        let context = preparationContext()
        let old = try await coordinator.prepare(context: context)
        // Hit 2 is the confirmation's package observation.
        var confirmed = false
        let operation = Task { @MainActor in
            do { confirmed = try await coordinator.confirm(old, context: context) }
            catch { Issue.record("Unexpected confirmation error: \(error)") }
        }
        await barrier.waitUntilBlocked()
        await #expect(throws: KnitNoteBackupError.operationInProgress) {
            _ = try await coordinator.prepare(context: preparationContext())
        }
        await #expect(throws: KnitNoteBackupError.operationInProgress) {
            try await coordinator.confirm(old, context: context)
        }
        barrier.release()
        await operation.value
        #expect(confirmed)
    }

    @Test func callerCancellationDuringConfirmationRevokesIntent() async throws {
        let fixture = try sourceFixture()
        defer { fixture.remove() }
        let barrier = NativePreparationBarrier(blockOnHit: 2)
        defer { barrier.release() }
        let service = KnitNoteBackupService(liveRoot: fixture.service.liveRoot, workRoot: fixture.service.workRoot,
            beforeLegacyImportPackageFinalPathValidation: { _ in barrier.block() })
        let coordinator = LegacyImportPreparationCoordinator(service: service)
        let context = preparationContext()
        let proposal = try await coordinator.prepare(context: context)
        var confirmed = true
        let operation = Task { @MainActor in
            do { confirmed = try await coordinator.confirm(proposal, context: context) }
            catch { Issue.record("Unexpected confirmation error: \(error)") }
        }
        await barrier.waitUntilBlocked()
        operation.cancel()
        barrier.release()
        await operation.value
        #expect(!confirmed)
        #expect(try await coordinator.confirm(proposal, context: context) == false)
        await coordinator.stopAndDrain()
        #expect(try fixture.packages().count == 1)
    }
}

private struct PreparationSourceFixture {
    let service: KnitNoteBackupService
    let root: URL
    let archiveURL: URL
    let bytes: Data
    let photoURL: URL?

    func packages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: service.workRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "knitnote-backup" }
            .sorted { $0.path < $1.path }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func sourceFixture(photoBytes: Data? = nil) throws -> PreparationSourceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let live = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    var projects: [StoredProject] = []
    var photoURL: URL?
    if let photoBytes {
        let projectID = UUID()
        let filename = "\(projectID.uuidString)-\(UUID().uuidString).jpg"
        var project = try StoredProject(id: projectID, name: "Preparation")
        project.setPhotoFilename(filename)
        projects.append(project)
        let url = live.appendingPathComponent("ProjectPhotos/\(filename)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try photoBytes.write(to: url)
        photoURL = url
    }
    let bytes = try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: projects))
    let archiveURL = live.appendingPathComponent("projects-v1.json")
    try bytes.write(to: archiveURL)
    return PreparationSourceFixture(
        service: KnitNoteBackupService(liveRoot: live, workRoot: root.appendingPathComponent("Work")),
        root: root, archiveURL: archiveURL, bytes: bytes, photoURL: photoURL
    )
}

private func preparationContext(
    source: LegacyLocalImportSource = .availableLocalHistoryUnknown,
    accountDigest: Data = Data(repeating: 1, count: 32)
) -> LegacyImportPreparationContext {
    LegacyImportPreparationContext(sourceSession: UUID(), targetSession: UUID(),
        accountDigest: accountDigest, source: source)
}

// Locks protect synchronous native hook state only; no lock survives an async suspension.
private final class NativePreparationBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockOnHit: Int
    private var hits = 0
    private var blocked = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?

    init(blockOnHit: Int = 1) { self.blockOnHit = blockOnHit }

    func block() {
        condition.lock()
        defer { condition.unlock() }
        hits += 1
        guard hits == blockOnHit else { return }
        blocked = true
        arrival?.resume()
        arrival = nil
        while !released { condition.wait() }
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if blocked { continuation.resume() } else { arrival = continuation }
            condition.unlock()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor private final class PreparationSignal {
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() { signalled = true; continuation?.resume(); continuation = nil }
    func wait() async {
        await withCheckedContinuation { continuation in
            if signalled { continuation.resume() } else { self.continuation = continuation }
        }
    }
}
