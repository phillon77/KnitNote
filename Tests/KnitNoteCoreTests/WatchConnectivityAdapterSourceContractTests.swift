import Foundation
import Testing

@Suite struct WatchConnectivityAdapterSourceContractTests {
    @Test func adaptersIsolateCallbacksAndExposeInjectableSessionOperations() throws {
        for path in [
            "KnitNote/WatchSync/PhoneWatchSession.swift",
            "KnitNoteWatch/Sync/WatchSession.swift"
        ] {
            let adapter = try source(path)

            #expect(adapter.contains("protocol WatchConnectivitySessionOperations"))
            #expect(adapter.contains("extension WCSession: WatchConnectivitySessionOperations"))
            #expect(adapter.contains("@MainActor\nfinal class"))
            #expect(adapter.contains("any WatchConnectivitySessionOperations"))
            #expect(adapter.contains("isSupported: @escaping @Sendable () -> Bool"))
            #expect(adapter.contains("nonisolated func session("))
            #expect(adapter.contains("Task { @MainActor"))
            #expect(!adapter.contains("final class PhoneWatchSession: NSObject, WCSessionDelegate, @unchecked Sendable"))
            #expect(!adapter.contains("final class WatchSession: NSObject, WCSessionDelegate, @unchecked Sendable"))
        }
    }

    @Test func interactiveCallbacksHaveOneShotFailurePaths() throws {
        for path in [
            "KnitNote/WatchSync/PhoneWatchSession.swift",
            "KnitNoteWatch/Sync/WatchSession.swift"
        ] {
            let adapter = try source(path)

            #expect(adapter.contains("WatchConnectivityReplyHandlerBox"))
            #expect(adapter.contains("replyBox.fail()"))
            #expect(adapter.contains("WatchConnectivityMessageCompletion"))
            #expect(!adapter.contains("guard let dictionary = try? envelope.dictionaryRepresentation() else { return }"))
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
