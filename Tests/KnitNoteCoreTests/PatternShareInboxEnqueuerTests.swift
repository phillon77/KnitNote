import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite(.serialized) struct PatternShareInboxEnqueuerTests {
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

    @Test(arguments: [
        (UTType.pdf.identifier, "Cable Chart", "Cable Chart.pdf"),
        (UTType.png.identifier, "Colorwork.png", "Colorwork.png"),
        (UTType.jpeg.identifier, "Sleeve Photo.jpeg", "Sleeve Photo.jpg"),
        (UTType.heic.identifier, "Finished Sweater", "Finished Sweater.heic"),
    ])
    func providerTypeAndSuggestedNameOwnTheFilenameWhenTemporaryURLHasNoExtension(
        typeIdentifier: String,
        suggestedName: String,
        expectedFilename: String
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternShareSuggestedName-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let inboxRoot = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sourceRoot.appendingPathComponent(UUID().uuidString)
        try makeSharedPattern(at: source, typeIdentifier: typeIdentifier)
        let expectedBytes = try Data(contentsOf: source)

        let item = try PatternShareInboxEnqueuer(inboxRoot: inboxRoot).enqueue(
            source: source,
            suggestedName: suggestedName,
            typeIdentifier: typeIdentifier,
            now: Date(timeIntervalSince1970: 1_753_500_001)
        )

        #expect(item.originalFilename == expectedFilename)
        #expect(try Data(contentsOf:
            PatternInboxFileService(root: inboxRoot).stagedURL(for: item)
        ) == expectedBytes)
    }

    @Test(arguments: [
        ("../../Secret\nChart.exe", UTType.pdf.identifier, "SecretChart.pdf"),
        ("..\\..\\Chart.PNG", UTType.png.identifier, "Chart.png"),
        ("", UTType.jpeg.identifier, "Pattern.jpg"),
        ("///", UTType.heic.identifier, "Pattern.heic"),
    ])
    func suggestedFilenameIsSafeAndCanonical(
        suggestedName: String,
        typeIdentifier: String,
        expectedFilename: String
    ) throws {
        #expect(
            try PatternShareImportFilename.safeFilename(
                suggestedName: suggestedName,
                typeIdentifier: typeIdentifier
            ) == expectedFilename
        )
    }

    @Test func suggestedFilenameHasABoundedLengthAndPreservesFriendlyNames() throws {
        #expect(
            try PatternShareImportFilename.safeFilename(
                suggestedName: "Summer Cardigan 2026.pdf",
                typeIdentifier: UTType.pdf.identifier
            ) == "Summer Cardigan 2026.pdf"
        )

        let bounded = try PatternShareImportFilename.safeFilename(
            suggestedName: String(repeating: "編", count: 300) + ".pdf",
            typeIdentifier: UTType.pdf.identifier
        )
        #expect(bounded.utf8.count <= 128)
        #expect(bounded.hasSuffix(".pdf"))
        #expect(!bounded.contains("/"))
        #expect(!bounded.contains("\\"))
        #expect(bounded.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        })
    }

    @Test func declaredProviderTypeMustMatchTheActualFileContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternShareTypeMismatch-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let inboxRoot = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sourceRoot.appendingPathComponent(UUID().uuidString)
        try makeSharedPattern(at: source, typeIdentifier: UTType.jpeg.identifier)

        #expect(throws: PatternFileError.invalidContent) {
            _ = try PatternShareInboxEnqueuer(inboxRoot: inboxRoot).enqueue(
                source: source,
                suggestedName: "Disguised.png",
                typeIdentifier: UTType.png.identifier,
                now: .now
            )
        }
        #expect(try PatternInboxFileService(root: inboxRoot).items().isEmpty)
        #expect(try ownedInboxArtifacts(at: inboxRoot).isEmpty)
    }

    @Test func cancellationDuringCandidateCopyPublishesNothingAndCleansEveryArtifact() throws {
        let root = try makeShareRaceRoot(named: "Copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source/\(UUID().uuidString)")
        try makeTestPatternPDF(at: source)
        let copyStarted = DispatchSemaphore(value: 0)
        let allowCopyToReturn = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        let operation = PatternShareImportOperationCoordinator()
        #expect(operation.beginProviderCallback())
        let result = LockedResult<PatternInboxItem>()
        let inbox = PatternInboxFileService(
            root: root.appendingPathComponent("Inbox", isDirectory: true),
            copyItem: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                copyStarted.signal()
                _ = allowCopyToReturn.wait(timeout: .now() + 2)
            }
        )
        let enqueuer = PatternShareInboxEnqueuer(
            inboxService: inbox,
            startAccessing: { _ in false },
            stopAccessing: { _ in }
        )

        DispatchQueue.global().async {
            result.capture {
                try enqueuer.enqueue(
                    source: source,
                    suggestedName: "Copy Race.pdf",
                    typeIdentifier: UTType.pdf.identifier,
                    now: .now,
                    cancellationToken: operation.cancellationToken
                )
            }
            operationFinished.signal()
        }

        #expect(copyStarted.wait(timeout: .now() + 2) == .success)
        #expect(operation.cancel() == .cancelRequest)
        allowCopyToReturn.signal()
        #expect(operationFinished.wait(timeout: .now() + 2) == .success)
        #expect(result.error is CancellationError)
        #expect(!operation.finishProcessing())
        #expect(try PatternInboxFileService(root: inbox.root).items().isEmpty)
        #expect(try ownedInboxArtifacts(at: inbox.root).isEmpty)
    }

    @Test func manifestCommitWinsAtomicallyOverConcurrentCancellation() throws {
        let root = try makeShareRaceRoot(named: "Commit")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source/\(UUID().uuidString)")
        try makeTestPatternPDF(at: source)
        let manifestWriteStarted = DispatchSemaphore(value: 0)
        let allowManifestCommit = DispatchSemaphore(value: 0)
        let enqueueFinished = DispatchSemaphore(value: 0)
        let cancelStarted = DispatchSemaphore(value: 0)
        let cancelFinished = DispatchSemaphore(value: 0)
        let operation = PatternShareImportOperationCoordinator()
        #expect(operation.beginProviderCallback())
        let itemResult = LockedResult<PatternInboxItem>()
        let actionResult = LockedValue<PatternShareImportTerminalAction>()
        let inbox = PatternInboxFileService(
            root: root.appendingPathComponent("Inbox", isDirectory: true),
            writeData: { data, destination in
                manifestWriteStarted.signal()
                _ = allowManifestCommit.wait(timeout: .now() + 2)
                try data.write(to: destination, options: .atomic)
            }
        )
        let enqueuer = PatternShareInboxEnqueuer(
            inboxService: inbox,
            startAccessing: { _ in false },
            stopAccessing: { _ in }
        )

        DispatchQueue.global().async {
            itemResult.capture {
                try enqueuer.enqueue(
                    source: source,
                    suggestedName: "Committed.pdf",
                    typeIdentifier: UTType.pdf.identifier,
                    now: .now,
                    cancellationToken: operation.cancellationToken
                )
            }
            enqueueFinished.signal()
        }
        #expect(manifestWriteStarted.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            cancelStarted.signal()
            actionResult.set(operation.cancel())
            cancelFinished.signal()
        }
        #expect(cancelStarted.wait(timeout: .now() + 2) == .success)
        #expect(cancelFinished.wait(timeout: .now() + 0.05) == .timedOut)
        allowManifestCommit.signal()

        #expect(enqueueFinished.wait(timeout: .now() + 2) == .success)
        #expect(cancelFinished.wait(timeout: .now() + 2) == .success)
        let item = try #require(itemResult.value)
        #expect(itemResult.error == nil)
        #expect(actionResult.value == .completeRequest)
        #expect(!operation.finishProcessing())
        #expect(try PatternInboxFileService(root: inbox.root).items() == [item])
        #expect(try ownedInboxArtifacts(at: inbox.root).map(\.lastPathComponent).sorted() == [
            item.stagedFilename,
            "\(item.id.uuidString).json",
        ].sorted())
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

private func makeSharedPattern(
    at url: URL,
    typeIdentifier: String
) throws {
    if typeIdentifier == UTType.pdf.identifier {
        try makeTestPatternPDF(at: url)
        return
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 8,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        typeIdentifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func ownedInboxArtifacts(at root: URL) throws -> [URL] {
    try [".Candidates", "Items", "Manifests", ".Quarantine"].flatMap { name -> [URL] in
        let directory = root.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
    }
}

private func makeShareRaceRoot(named name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PatternShareRace-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Source", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private final class LockedResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?
    private var storedError: (any Error)?

    var value: Value? {
        lock.withLock { storedValue }
    }

    var error: (any Error)? {
        lock.withLock { storedError }
    }

    func capture(_ operation: () throws -> Value) {
        lock.withLock {
            do {
                storedValue = try operation()
            } catch {
                storedError = error
            }
        }
    }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock {
            storage = value
        }
    }
}
