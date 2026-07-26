import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternShareInboxEnqueuerTests {
    @Test func enqueuerOwnsSecurityScopeAndCreatesOnlyAShareInboxItem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternShareInboxEnqueuer-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let inboxRoot = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sourceRoot.appendingPathComponent("Summer Cardigan.pdf")
        try makeTestPatternPDF(at: source)
        let scope = SecurityScopeRecorder()
        let receivedAt = Date(timeIntervalSince1970: 1_753_500_000)
        let enqueuer = PatternShareInboxEnqueuer(
            inboxRoot: inboxRoot,
            startAccessing: { url in
                scope.recordStart(url)
                return true
            },
            stopAccessing: { url in
                scope.recordStop(url)
            }
        )

        let item = try enqueuer.enqueue(source: source, now: receivedAt)

        #expect(item.originalFilename == "Summer Cardigan.pdf")
        #expect(item.receivedAt == receivedAt)
        #expect(item.origin == .shareExtension)
        #expect(item.targetProjectID == nil)
        #expect(scope.started == [source])
        #expect(scope.stopped == [source])
        #expect(try PatternInboxFileService(root: inboxRoot).items() == [item])
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("projects-v1.json").path
        ))
    }

    @Test func enqueuerDoesNotStopSecurityScopeWhenNoneWasAcquired() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternShareInboxNoScope-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let inboxRoot = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sourceRoot.appendingPathComponent("Chart.pdf")
        try makeTestPatternPDF(at: source)
        let scope = SecurityScopeRecorder()
        let enqueuer = PatternShareInboxEnqueuer(
            inboxRoot: inboxRoot,
            startAccessing: { url in
                scope.recordStart(url)
                return false
            },
            stopAccessing: { url in
                scope.recordStop(url)
            }
        )

        _ = try enqueuer.enqueue(source: source, now: .now)

        #expect(scope.started == [source])
        #expect(scope.stopped.isEmpty)
    }
}

private final class SecurityScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var startedStorage: [URL] = []
    private var stoppedStorage: [URL] = []

    var started: [URL] {
        lock.withLock { startedStorage }
    }

    var stopped: [URL] {
        lock.withLock { stoppedStorage }
    }

    func recordStart(_ url: URL) {
        lock.withLock {
            startedStorage.append(url)
        }
    }

    func recordStop(_ url: URL) {
        lock.withLock {
            stoppedStorage.append(url)
        }
    }
}
