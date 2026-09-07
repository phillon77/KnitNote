import Combine
import CoreGraphics
import Foundation
import Testing
@testable import KnitNote

@MainActor
@Suite struct AppSessionCompositionTests {
    // Catches a reused presenter/inbox or a group missing any real producer.
    @Test func oldAndNewSessionPresentationNeverMix() async throws {
        try await withCompositionFixture { fixture in
            let first = try fixture.makeSession()
            let second = try fixture.makeSession()
            try first.store.add(name: "First fixed store")
            try second.store.add(name: "Second fixed store")
            let a = try #require(first.presentation)
            let b = try #require(second.presentation)
            #expect(a.patternInboxProcessor !== b.patternInboxProcessor)
            #expect(a.patternBackupReminderPresenter !== b.patternBackupReminderPresenter)
            #expect(a.reminderPresentationStore !== b.reminderPresentationStore)
            #expect(fixture.natives.allSatisfy { $0.activations == 0 })
            let owner = AppSessionOwner()
            try owner.publishPreparedSession(first, for: owner.generation)
            a.watch?.coordinator.start()
            #expect(fixture.natives[0].activations == 1)
            #expect(fixture.natives[0].snapshots.last?.projects.map(\.name) == ["First fixed store"])
            let generation = owner.beginTransition()
            try await owner.waitForRetiredSessions()
            // Each real producer's own join rejects if it was not stopped.
            try await a.patternInboxProcessor.waitForStoppedOperations()
            try await a.watch?.coordinator.waitForStoppedOperations()
            try await a.watch?.adapter.waitForStoppedOperations()
            #expect(fixture.natives[0].removals == 1)
            try owner.publishPreparedSession(second, for: generation)
            #expect(owner.visibleSession === second)
            #expect(first.store.isSessionWriteRevoked)
            #expect(!second.store.isSessionWriteRevoked)
            a.watch?.coordinator.start()
            a.watch?.adapter.activate()
            #expect(fixture.natives[0].activations == 1)
            b.watch?.coordinator.start()
            #expect(fixture.natives[1].snapshots.last?.projects.map(\.name) == ["Second fixed store"])
        }
    }

    // Catches an inbox bound to another store: processing must publish into A.
    @Test func composedInboxUsesItsFixedStoreAndPresenter() async throws {
        try await withCompositionFixture { fixture in
            let directory = fixture.root.appending(path: "inbox-session")
            let store = fixture.makeStore(at: directory)
            let session = try fixture.makeSession(store: store, withWatch: false)
            let presentation = try #require(session.presentation)
            let inbox = PatternInboxFileService(root: directory.appending(path: "KnitNote/PatternInbox"))
            let url = fixture.root.appending(path: "pattern.pdf")
            var page = CGRect(x: 0, y: 0, width: 100, height: 100)
            let context = try #require(CGContext(url as CFURL, mediaBox: &page, nil))
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
            _ = try inbox.enqueue(source: url, origin: .library, targetProjectID: nil, now: .now)
            // Signal from the real presenter's publication; bounded by suite
            // execution timeout, not a scheduling assumption or empty Task.
            let published = ProducerTestMainActorEvent()
            let observation = presentation.patternInboxProcessor.$notice.sink { notice in
                if notice != nil { published.signal() }
            }
            defer { observation.cancel() }
            presentation.patternInboxProcessor.processPending()
            await published.wait()
            #expect(store.patterns.count == 1)
            #expect(presentation.patternInboxProcessor.notice?.importCount == 1)
            #expect(presentation.patternBackupReminderPresenter.isPresented)
        }
    }

    // Catches opening local production dependencies before screenshot routing.
    @Test func screenshotLaunchNeverConstructsLocalDependencies() async throws {
        try await withCompositionFixture { fixture in
            var localCalls = 0
            let launch = try AppSessionComposition.makeLaunch(
                screenshotBaseDirectory: fixture.root.appending(path: "screenshot"),
                backupHistory: BackupHistory(defaults: fixture.defaults),
                makeScreenshotStore: { directory, entitlement in
                    #expect(directory == fixture.root.appending(path: "screenshot"))
                    #expect(entitlement.allowsWrites)
                    return fixture.makeStore(at: directory)
                },
                makeLocal: {
                    localCalls += 1
                    throw CompositionFailure.forbiddenLiveFactory
                }
            )
            fixture.sessions.append(launch.session)
            #expect(localCalls == 0)
            #expect(launch.languageSelectionProjection == nil)
            #expect(launch.session.presentation?.watch == nil)
            try launch.session.store.add(name: "Screenshot only")
            #expect(launch.session.store.projects.count == 1)
        }
    }

    @Test func failedWatchFactoryDoesNotStartInboxOrRevokeUnacceptedStore() async throws {
        try await withCompositionFixture { fixture in
            let store = fixture.makeStore()
            #expect(throws: CompositionFailure.forbiddenLiveFactory) {
                try AppSessionComposition.make(store: store, backupHistory: BackupHistory(defaults: fixture.defaults)) { _ in
                    throw CompositionFailure.forbiddenLiveFactory
                }
            }
            #expect(!store.isSessionWriteRevoked)
            try store.add(name: "Still caller owned")
        }
    }

    @Test func localLaunchBuildsOneFullCompositionWithoutStartingWatch() async throws {
        try await withCompositionFixture { fixture in
            let fixedStore = fixture.makeStore()
            let entitlement = EntitlementCoordinator.configured(screenshotMode: true)
            let projection = LanguageSelectionProjection(defaults: fixture.defaults)
            var localCalls = 0
            var watchCalls = 0
            let launch = try AppSessionComposition.makeLaunch(
                screenshotBaseDirectory: nil,
                backupHistory: BackupHistory(defaults: fixture.defaults),
                makeScreenshotStore: { _, _ in throw CompositionFailure.forbiddenLiveFactory },
                makeLocal: {
                    localCalls += 1
                    return AppSessionLocalDependencies(
                        store: fixedStore,
                        entitlementCoordinator: entitlement,
                        languageSelectionProjection: projection,
                        makeWatch: { store in
                            watchCalls += 1
                            #expect(store === fixedStore)
                            return fixture.makeWatch(store: store)
                        }
                    )
                }
            )
            fixture.sessions.append(launch.session)
            #expect(localCalls == 1 && watchCalls == 1)
            #expect(launch.entitlementCoordinator === entitlement)
            #expect(launch.session.presentation?.watch?.adapter === fixture.watches.first?.adapter)
            #expect(fixture.natives[0].activations == 0)
            launch.languageSelectionProjection?.write(.english)
            #expect(projection.readSelection() == .english)
        }
    }

    @Test func failedIsolatedStoreDoesNotFallBackToLocalFactories() async throws {
        try await withCompositionFixture { fixture in
            var localCalls = 0
            #expect(throws: CompositionFailure.forbiddenLiveFactory) {
                try AppSessionComposition.makeLaunch(
                    screenshotBaseDirectory: fixture.root,
                    backupHistory: BackupHistory(defaults: fixture.defaults),
                    makeScreenshotStore: { _, _ in throw CompositionFailure.forbiddenLiveFactory },
                    makeLocal: {
                        localCalls += 1
                        throw CompositionFailure.forbiddenLiveFactory
                    }
                )
            }
            #expect(localCalls == 0)
        }
    }
}

private enum CompositionFailure: Error { case forbiddenLiveFactory }
