import CoreGraphics
import Foundation
import Testing
@testable import KnitNote

@MainActor
@Suite(.serialized)
struct AppSessionProducerGroupTests {
    @Test func mixedSessionStopsActualInboxAndWatchWithoutTouchingIndependentSession() async throws {
        try await withProducerGroupFixture { fixture in
            let project = try #require(fixture.aStore.projects.first)
            let counter = try #require(project.counters.first)
            let command = try WatchCounterCommand(
                validating: WatchCounterCommand.currentSchemaVersion,
                id: UUID(),
                projectID: project.id,
                counterID: counter.id,
                operation: .increment,
                createdAt: fixture.now
            )

            fixture.watch.start()
            let ingress = try #require(fixture.transport.onReceivedEnvelope)
            fixture.inbox.processPending()
            await fixture.processing.waitUntilProcessStarts()

            let sourceBefore = try Data(contentsOf: fixture.sourceURL)
            let aBefore = try ProducerTestDiskSnapshot.capture(root: fixture.aRoot)
            let bBefore = try ProducerTestDiskSnapshot.capture(root: fixture.bRoot)
            let contextsBefore = fixture.transport.applicationContexts
            let transfersBefore = fixture.transport.sentEnvelopes
            let messagesBefore = fixture.transport.sentMessages

            ingress(.command(command), nil)
            fixture.group.stopForSessionTransition()

            #expect(fixture.aStore.isSessionWriteRevoked)
            #expect(throws: StoreSessionAccessError.revoked) {
                try fixture.aStore.add(name: "A must reject late writes")
            }
            #expect(!fixture.bStore.isSessionWriteRevoked)
            #expect(try ProducerTestDiskSnapshot.capture(root: fixture.bRoot) == bBefore)

            let entered = ProducerTestMainActorEvent()
            let completed = ProducerTestMainActorEvent()
            let groupWaiter = Task { @MainActor in
                entered.signal()
                try await fixture.group.waitForStoppedOperations()
                completed.signal()
            }
            let watchWaiter = Task { @MainActor in
                try await fixture.watch.waitForStoppedOperations()
            }
            await entered.wait()
            try await watchWaiter.value
            #expect(completed.count == 0)

            await fixture.processing.release()
            try await groupWaiter.value

            #expect(completed.count == 1)
            #expect(fixture.inbox.pendingSelection == nil)
            #expect(fixture.inbox.failure == nil)
            #expect(fixture.inbox.notice == nil)
            #expect(!fixture.presenter.isPresented)
            #expect(fixture.aStore.project(id: project.id)?.counters.first?.value == 0)
            #expect(fixture.transport.applicationContexts == contextsBefore)
            #expect(fixture.transport.sentEnvelopes == transfersBefore)
            #expect(fixture.transport.sentMessages == messagesBefore)
            #expect(try ProducerTestDiskSnapshot.capture(root: fixture.aRoot) == aBefore)
            #expect(try Data(contentsOf: fixture.sourceURL) == sourceBefore)
            #expect(try ProducerTestDiskSnapshot.capture(root: fixture.bRoot) == bBefore)

            try fixture.bStore.add(name: "B remains active")
            #expect(Set(fixture.bStore.projects.map(\.name)) == ["B", "B remains active"])
        }
    }

    @Test func emptyProducerGroupWaitsForActualStoreNativeCopyTermination() async throws {
        let fixture = try ProducerGroupNativeImportFixture()
        let operation = Task { @MainActor in
            defer { fixture.copyBlocker.finishObservation(reachedHook: false) }
            return try await fixture.aStore.importPattern(
                from: fixture.sourceURL,
                projectID: fixture.aProjectID
            )
        }

        let result: Result<Void, any Error>
        do {
            let reachedCopy = await fixture.copyBlocker.waitForObservation()
            #expect(reachedCopy)
            guard reachedCopy else {
                throw ProducerGroupTestError.nativeCopyDidNotStart
            }
            let sourceBefore = try Data(contentsOf: fixture.sourceURL)
            let bBefore = try ProducerTestDiskSnapshot.capture(root: fixture.bRoot)

            fixture.group.stopForSessionTransition()
            #expect(fixture.aStore.isSessionWriteRevoked)
            let entered = ProducerTestMainActorEvent()
            let completed = ProducerTestMainActorEvent()
            let drain = Task { @MainActor in
                entered.signal()
                try await fixture.group.waitForStoppedOperations()
                completed.signal()
            }
            await entered.wait()
            #expect(completed.count == 0)

            fixture.copyBlocker.release()
            await #expect(throws: StoreSessionAccessError.revoked) {
                try await operation.value
            }
            try await drain.value

            #expect(completed.count == 1)
            #expect(fixture.aStore.projects.first?.patterns.isEmpty == true)
            #expect(try Data(contentsOf: fixture.sourceURL) == sourceBefore)
            #expect(try ProducerTestDiskSnapshot.capture(root: fixture.bRoot) == bBefore)
            try fixture.bStore.add(name: "B remains active")
            #expect(Set(fixture.bStore.projects.map(\.name)) == ["B", "B remains active"])
            result = .success(())
        } catch {
            result = .failure(error)
        }

        fixture.copyBlocker.release()
        fixture.group.stopForSessionTransition()
        _ = try? await operation.value
        _ = try? await fixture.group.waitForStoppedOperations()
        fixture.cleanup()
        try result.get()
    }

    @Test func waitBeforeStopRejectsOpenGroup() async throws {
        try await withProducerGroupFixture { fixture in
            await #expect(throws: AppSessionProducerDrainError.producerStillActive) {
                try await fixture.group.waitForStoppedOperations()
            }
        }
    }

    @Test func emptyProducerGroupRevokesAndDrainsItsFixedStore() async throws {
        let fixture = try ProducerGroupBareFixture()
        defer { fixture.cleanup() }
        let group = AppSessionProducerGroup(store: fixture.store, producers: [])

        group.stopForSessionTransition()

        #expect(fixture.store.isSessionWriteRevoked)
        #expect(throws: StoreSessionAccessError.revoked) {
            try fixture.store.add(name: "late")
        }
        try await group.waitForStoppedOperations()
    }

    @Test func repeatedStopIsSafeAndRemainsIrreversible() async throws {
        try await withProducerGroupFixture { fixture in
            fixture.group.stopForSessionTransition()
            fixture.group.stopForSessionTransition()
            await fixture.processing.release()

            try await fixture.group.waitForStoppedOperations()
            fixture.group.stopForSessionTransition()
            try await fixture.group.waitForStoppedOperations()
            #expect(fixture.aStore.isSessionWriteRevoked)
        }
    }

    @Test func twoGroupWaitersJoinTheSameActualProducerWork() async throws {
        try await withProducerGroupFixture { fixture in
            fixture.inbox.processPending()
            await fixture.processing.waitUntilProcessStarts()
            fixture.group.stopForSessionTransition()

            let entered = ProducerTestMainActorEvent()
            let completed = ProducerTestMainActorEvent()
            let first = Task { @MainActor in
                entered.signal()
                try await fixture.group.waitForStoppedOperations()
                completed.signal()
            }
            let second = Task { @MainActor in
                entered.signal()
                try await fixture.group.waitForStoppedOperations()
                completed.signal()
            }
            await entered.wait(for: 2)
            #expect(completed.count == 0)

            await fixture.processing.release()
            try await first.value
            try await second.value
            #expect(completed.count == 2)
        }
    }

    @Test func cancellingOneGroupWaiterDoesNotCancelAcceptedWorkOrItsPeer() async throws {
        try await withProducerGroupFixture { fixture in
            fixture.inbox.processPending()
            await fixture.processing.waitUntilProcessStarts()
            fixture.group.stopForSessionTransition()

            let entered = ProducerTestMainActorEvent()
            let completed = ProducerTestMainActorEvent()
            let cancelled = Task { @MainActor () -> (any Error)? in
                entered.signal()
                do {
                    try await fixture.group.waitForStoppedOperations()
                    completed.signal()
                    return nil
                } catch {
                    completed.signal()
                    return error
                }
            }
            let peer = Task { @MainActor () -> (any Error)? in
                entered.signal()
                do {
                    try await fixture.group.waitForStoppedOperations()
                    completed.signal()
                    return nil
                } catch {
                    completed.signal()
                    return error
                }
            }
            await entered.wait(for: 2)
            cancelled.cancel()
            #expect(completed.count == 0)

            await fixture.processing.release()
            let cancelledError = await cancelled.value
            let peerError = await peer.value
            #expect(cancelledError is CancellationError)
            #expect(peerError == nil)
            #expect(completed.count == 2)
        }
    }

    @Test func cancelledFixtureCallerStillJoinsInboxBeforeDeletingRoot() async throws {
        let operationStarted = ProducerTestMainActorEvent()
        let operationRelease = ProducerTestMainActorEvent()
        let terminationObservedBeforeDelete = ProducerTestMainActorEvent()
        var fixtureRoot: URL?

        let caller = Task { @MainActor in
            try await withProducerGroupFixture(
                observeInboxDrainBeforeDelete: { result, fixture in
                    let succeededWithoutSafetyJoin: Bool
                    switch result {
                    case .success:
                        succeededWithoutSafetyJoin = true
                    case .failure:
                        succeededWithoutSafetyJoin = false
                        let safetyJoin = Task { @MainActor in
                            fixture.inbox.stopForSessionTransition()
                            try await fixture.inbox.waitForStoppedOperations()
                        }
                        try await safetyJoin.value
                    }
                    #expect(succeededWithoutSafetyJoin)
                    #expect(FileManager.default.fileExists(atPath: fixture.root.path))
                    terminationObservedBeforeDelete.signal()
                }
            ) { fixture in
                fixtureRoot = fixture.root
                fixture.inbox.processPending()
                await fixture.processing.waitUntilProcessStarts()
                operationStarted.signal()
                await operationRelease.wait()
                try Task.checkCancellation()
            }
        }

        await operationStarted.wait()
        caller.cancel()
        operationRelease.signal()
        await #expect(throws: CancellationError.self) {
            try await caller.value
        }

        #expect(terminationObservedBeforeDelete.count == 1)
        #expect(fixtureRoot.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}

private enum ProducerGroupTestError: Error {
    case fixtureCreationFailed
    case nativeCopyDidNotStart
}

@MainActor
private struct ProducerGroupBareFixture {
    let root: URL
    let store: JSONProjectStore

    init() throws {
        let root = URL(
            filePath: "/tmp/AppSessionProducerGroupTests-Bare-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let liveRoot = root.appending(path: "Live", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        let store = JSONProjectStore(url: liveRoot.appending(path: "projects.json"))
        try store.add(name: "A")
        self.root = root
        self.store = store
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private struct ProducerGroupFixture {
    let root: URL
    let aRoot: URL
    let bRoot: URL
    let sourceURL: URL
    let sourceBytes: Data
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let now: Date
    let aStore: JSONProjectStore
    let bStore: JSONProjectStore
    let processing: ProducerTestInboxProcessing
    let presenter: PatternBackupReminderPresenter
    let inbox: PatternInboxProcessor
    let transport: ProducerTestWatchTransport
    let watch: PhoneWatchSyncCoordinator
    let group: AppSessionProducerGroup

    init() throws {
        let root = URL(
            filePath: "/tmp/AppSessionProducerGroupTests-Mixed-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let aRoot = root.appending(path: "A", directoryHint: .isDirectory)
        let bRoot = root.appending(path: "B", directoryHint: .isDirectory)
        let aLive = aRoot.appending(path: "Live", directoryHint: .isDirectory)
        let bLive = bRoot.appending(path: "Live", directoryHint: .isDirectory)
        let watchRoot = aRoot.appending(path: "Watch", directoryHint: .isDirectory)
        let incomingRoot = aRoot.appending(path: "Incoming", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: aLive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bLive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        let sourceURL = incomingRoot.appending(path: "fixture.pdf")
        try makeProducerGroupPDF(at: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)

        let aStore = JSONProjectStore(url: aLive.appending(path: "projects.json"))
        let bStore = JSONProjectStore(url: bLive.appending(path: "projects.json"))
        try aStore.add(name: "A")
        try bStore.add(name: "B")

        let suiteName = "ProducerTest.AppSessionProducerGroup.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ProducerGroupTestError.fixtureCreationFailed
        }
        defaults.removePersistentDomain(forName: suiteName)
        let presenter = PatternBackupReminderPresenter(history: BackupHistory(defaults: defaults))
        let item = PatternInboxItem(
            originalFilename: sourceURL.lastPathComponent,
            receivedAt: Date(timeIntervalSince1970: 1),
            origin: .shareExtension,
            targetProjectID: aStore.projects.first?.id,
            stagedFilename: sourceURL.lastPathComponent
        )
        let processing = ProducerTestInboxProcessing(
            item: item,
            result: .success(.created(patternID: UUID()))
        )
        let inbox = PatternInboxProcessor(
            driver: PatternInboxDriver(processing: processing),
            backupReminderPresenter: presenter
        )
        let transport = ProducerTestWatchTransport()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let watch = PhoneWatchSyncCoordinator(
            projectStore: aStore,
            entitlementCoordinator: .configured(screenshotMode: true),
            transport: transport,
            applicationSupportRoot: watchRoot,
            languageCode: { "en" },
            now: { now }
        )
        let group = AppSessionProducerGroup(
            store: aStore,
            producers: [watch, inbox]
        )

        self.root = root
        self.aRoot = aRoot
        self.bRoot = bRoot
        self.sourceURL = sourceURL
        self.sourceBytes = sourceBytes
        defaultsSuiteName = suiteName
        self.defaults = defaults
        self.now = now
        self.aStore = aStore
        self.bStore = bStore
        self.processing = processing
        self.presenter = presenter
        self.inbox = inbox
        self.transport = transport
        self.watch = watch
        self.group = group
    }

    func releaseJoinAndCleanup(
        observeInboxDrainBeforeDelete: @MainActor (
            Result<Void, any Error>,
            ProducerGroupFixture
        ) async throws -> Void = { _, _ in }
    ) async throws {
        await processing.release()
        transport.onActivate = nil
        transport.onUpdateApplicationContext = nil
        group.stopForSessionTransition()
        inbox.stopForSessionTransition()
        watch.stopForSessionTransition()
        do {
            try await inbox.waitForStoppedOperations()
        } catch {
            try await observeInboxDrainBeforeDelete(.failure(error), self)
            throw error
        }
        try await observeInboxDrainBeforeDelete(.success(()), self)
        try await watch.waitForStoppedOperations()
        try await group.waitForStoppedOperations()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func withProducerGroupFixture(
    observeInboxDrainBeforeDelete: @escaping @MainActor (
        Result<Void, any Error>,
        ProducerGroupFixture
    ) async throws -> Void = { _, _ in },
    operation: @MainActor (ProducerGroupFixture) async throws -> Void
) async throws {
    let fixture = try ProducerGroupFixture()
    let result: Result<Void, any Error>
    do {
        result = .success(try await operation(fixture))
    } catch {
        result = .failure(error)
    }
    let cleanup = Task { @MainActor in
        try await fixture.releaseJoinAndCleanup(
            observeInboxDrainBeforeDelete: observeInboxDrainBeforeDelete
        )
    }
    try await cleanup.value
    try result.get()
}

private final class ProducerGroupNativeCopyBlocker: @unchecked Sendable {
    private let observations: AsyncStream<Bool>
    private let observation: AsyncStream<Bool>.Continuation
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observationFinished = false
    private var isReleased = false

    init() {
        let events = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations = events.stream
        observation = events.continuation
    }

    func waitForObservation() async -> Bool {
        for await result in observations { return result }
        return false
    }

    func finishObservation(reachedHook: Bool) {
        lock.lock()
        guard !observationFinished else {
            lock.unlock()
            return
        }
        observationFinished = true
        lock.unlock()
        observation.yield(reachedHook)
        observation.finish()
    }

    func copyFile(from source: URL, to destination: URL) throws {
        finishObservation(reachedHook: true)
        releaseGate.wait()
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        releaseGate.signal()
    }
}

@MainActor
private struct ProducerGroupNativeImportFixture {
    let root: URL
    let bRoot: URL
    let sourceURL: URL
    let aStore: JSONProjectStore
    let bStore: JSONProjectStore
    let aProjectID: UUID
    let copyBlocker: ProducerGroupNativeCopyBlocker
    let group: AppSessionProducerGroup

    init() throws {
        let root = URL(
            filePath: "/tmp/AppSessionProducerGroupTests-Native-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let aLive = root.appending(path: "A/Live", directoryHint: .isDirectory)
        let bRoot = root.appending(path: "B", directoryHint: .isDirectory)
        let bLive = bRoot.appending(path: "Live", directoryHint: .isDirectory)
        let sourceRoot = root.appending(path: "A/Source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: aLive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bLive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceURL = sourceRoot.appending(path: "fixture.pdf")
        try makeProducerGroupPDF(at: sourceURL)

        let copyBlocker = ProducerGroupNativeCopyBlocker()
        let patternService = PatternFileService(
            root: aLive.appending(path: "Patterns", directoryHint: .isDirectory),
            copyFile: { try copyBlocker.copyFile(from: $0, to: $1) }
        )
        let aStore = JSONProjectStore(
            url: aLive.appending(path: "projects.json"),
            patternFileService: patternService
        )
        let bStore = JSONProjectStore(url: bLive.appending(path: "projects.json"))
        try aStore.add(name: "A")
        try bStore.add(name: "B")
        guard let aProjectID = aStore.projects.first?.id else {
            throw ProducerGroupTestError.fixtureCreationFailed
        }

        self.root = root
        self.bRoot = bRoot
        self.sourceURL = sourceURL
        self.aStore = aStore
        self.bStore = bStore
        self.aProjectID = aProjectID
        self.copyBlocker = copyBlocker
        group = AppSessionProducerGroup(store: aStore, producers: [])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeProducerGroupPDF(at url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw ProducerGroupTestError.fixtureCreationFailed
    }
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
}
