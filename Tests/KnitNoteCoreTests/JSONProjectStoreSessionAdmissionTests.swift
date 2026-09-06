import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
@Suite struct JSONProjectStoreSessionAdmissionTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-admission-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                               withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func withRoot(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-admission-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                               withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    @Test func retainedClosureCannotWriteAfterRevocation() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("projects-v1.json")
            let store = JSONProjectStore(url: url)
            try store.add(name: "Original")
            let id = try #require(store.projects.first?.id)
            let before = try Data(contentsOf: url)
            let lateSave: () throws -> Void = {
                try store.rename(id: id, to: "Late edit")
            }

            store.revokeSessionWrites()
            store.revokeSessionWrites()

            #expect(store.isSessionWriteRevoked)
            #expect(throws: StoreSessionAccessError.revoked) { try lateSave() }
            #expect(try Data(contentsOf: url) == before)
            #expect(store.projects.first?.name == "Original")
        }
    }

    @Test func revocationDoesNotConsumePurchaseAuthorization() throws {
        try withRoot { root in
            var calls = 0
            let url = root.appendingPathComponent("projects-v1.json")
            let store = JSONProjectStore(
                url: url,
                authorizeMutation: { _ in calls += 1; return .allow }
            )
            try store.add(name: "Original")
            let before = try Data(contentsOf: url)
            calls = 0
            store.revokeSessionWrites()

            #expect(throws: StoreSessionAccessError.revoked) {
                try store.add(name: "Rejected")
            }
            #expect(calls == 0)
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test(arguments: [FeatureAccessDecision.allow, .requiresUnlock])
    func authorizationCallbackRevocationWinsBeforeValidation(
        decision: FeatureAccessDecision
    ) async throws {
        try await withRoot { root in
            var store: JSONProjectStore?
            defer { store = nil }
            store = JSONProjectStore(
                url: root.appendingPathComponent("projects-v1.json"),
                authorizeMutation: { _ in
                    store?.revokeSessionWrites()
                    return decision
                }
            )
            let resolvedStore = try #require(store)

            await #expect(throws: StoreSessionAccessError.revoked) {
                _ = try await resolvedStore.addYouTubePattern(
                    link: YouTubePatternLink(videoID: "dQw4w9WgXcQ"),
                    title: " \n\t "
                )
            }
            #expect(resolvedStore.patterns.isEmpty)
            #expect(resolvedStore.patternAssets.isEmpty)
        }
    }

    @Test(arguments: [FeatureAccessDecision.allow, .requiresUnlock])
    func successfulPurchaseCallbackRevocationWinsBeforeValidation(
        decision: FeatureAccessDecision
    ) throws {
        try withRoot { root in
            var store: JSONProjectStore?
            defer { store = nil }
            store = JSONProjectStore(
                url: root.appendingPathComponent("projects-v1.json"),
                authorizeMutation: { _ in .startTrial },
                commitSuccessfulMutation: { _ in
                    store?.revokeSessionWrites()
                    return decision
                }
            )
            let resolvedStore = try #require(store)

            #expect(throws: StoreSessionAccessError.revoked) {
                try resolvedStore.addYarn(
                    StoredYarn(name: "Rejected"),
                    photoData: nil,
                    labelPhotos: [Data(), Data(), Data()]
                )
            }
            #expect(resolvedStore.yarns.isEmpty)
        }
    }

    @Test func persistPreservesSessionRevocationFromArchiveWriterSeam() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("projects-v1.json")
            let store = JSONProjectStore(
                url: url,
                backupService: KnitNoteBackupService(
                    liveRoot: root,
                    workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true)
                ),
                archiveWrite: { _, _ in throw StoreSessionAccessError.revoked }
            )

            #expect(throws: StoreSessionAccessError.revoked) {
                try store.add(name: "Rejected")
            }
            #expect(store.projects.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func revocationIsPerStoreNotGlobal() throws {
        try withRoot { root in
            let aURL = root.appendingPathComponent("a/projects-v1.json")
            let bURL = root.appendingPathComponent("b/projects-v1.json")
            for url in [aURL, bURL] {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            let a = JSONProjectStore(url: aURL)
            let b = JSONProjectStore(url: bURL)
            try a.add(name: "A")
            let beforeA = try Data(contentsOf: aURL)
            a.revokeSessionWrites()
            try b.add(name: "B")

            #expect(!b.isSessionWriteRevoked)
            #expect(b.projects.map(\.name) == ["B"])
            #expect(try Data(contentsOf: aURL) == beforeA)
            #expect(throws: StoreSessionAccessError.revoked) {
                try a.add(name: "Rejected")
            }
        }
    }

    @Test func maintenanceAndDeleteCannotBypassRevocation() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("projects-v1.json")
            let store = JSONProjectStore(url: url)
            try store.add(name: "Original")
            let id = try #require(store.projects.first?.id)
            let before = try Data(contentsOf: url)
            store.revokeSessionWrites()

            #expect(throws: StoreSessionAccessError.revoked) {
                try store.delete(id: id)
            }
            #expect(throws: StoreSessionAccessError.revoked) {
                try store.reloadFromDisk()
            }
            #expect(throws: StoreSessionAccessError.revoked) {
                try store.repairSyncPublication()
            }
            #expect(throws: StoreSessionAccessError.revoked) {
                try store.restoreRecentlyDeleted(id: id, now: .now)
            }
            store.retryLoad()
            #expect(try Data(contentsOf: url) == before)
            #expect(store.projects.map(\.name) == ["Original"])
        }
    }
}
