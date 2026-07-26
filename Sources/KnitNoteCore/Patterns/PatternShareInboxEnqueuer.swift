import Foundation
import UniformTypeIdentifiers

public struct PatternShareInboxEnqueuer: Sendable {
    public let inboxRoot: URL
    private let inboxService: PatternInboxFileService
    private let startAccessing: @Sendable (URL) -> Bool
    private let stopAccessing: @Sendable (URL) -> Void

    public init(inboxRoot: URL) {
        self.init(
            inboxService: PatternInboxFileService(root: inboxRoot),
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    init(
        inboxRoot: URL,
        startAccessing: @escaping @Sendable (URL) -> Bool,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        self.init(
            inboxService: PatternInboxFileService(root: inboxRoot),
            startAccessing: startAccessing,
            stopAccessing: stopAccessing
        )
    }

    init(
        inboxService: PatternInboxFileService,
        startAccessing: @escaping @Sendable (URL) -> Bool,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        inboxRoot = inboxService.root
        self.inboxService = inboxService
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    public func enqueue(
        source: URL,
        now: Date
    ) throws -> PatternInboxItem {
        let typeIdentifier: String
        switch source.pathExtension.lowercased() {
        case "pdf": typeIdentifier = UTType.pdf.identifier
        case "png": typeIdentifier = UTType.png.identifier
        case "jpg", "jpeg": typeIdentifier = UTType.jpeg.identifier
        case "heic": typeIdentifier = UTType.heic.identifier
        default: throw PatternFileError.unsupported
        }
        return try enqueue(
            source: source,
            suggestedName: source.lastPathComponent,
            typeIdentifier: typeIdentifier,
            now: now,
            cancellationToken: PatternInboxEnqueueCancellationToken()
        )
    }

    public func enqueue(
        source: URL,
        suggestedName: String?,
        typeIdentifier: String,
        now: Date,
        cancellationToken: PatternInboxEnqueueCancellationToken = .init()
    ) throws -> PatternInboxItem {
        let acquiredSecurityScope = startAccessing(source)
        defer {
            if acquiredSecurityScope {
                stopAccessing(source)
            }
        }
        let originalFilename = try PatternShareImportFilename.safeFilename(
            suggestedName: suggestedName,
            typeIdentifier: typeIdentifier
        )
        let declaredFileExtension = try PatternShareImportFilename
            .canonicalExtension(for: typeIdentifier)
        return try inboxService.enqueue(
            source: source,
            originalFilename: originalFilename,
            declaredFileExtension: declaredFileExtension,
            origin: .shareExtension,
            targetProjectID: nil,
            now: now,
            cancellationToken: cancellationToken
        )
    }
}
