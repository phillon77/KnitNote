import Foundation
import UniformTypeIdentifiers

public enum PatternShareImportSelectionError: Error, Equatable, Sendable {
    case noAttachment
    case multipleAttachments
    case unsupported
}

public enum PatternShareImportAttachmentSelector {
    public static func indexOfSingleSupportedFile(
        in registeredTypeIdentifiers: [[String]]
    ) throws -> Int {
        guard !registeredTypeIdentifiers.isEmpty else {
            throw PatternShareImportSelectionError.noAttachment
        }
        guard registeredTypeIdentifiers.count == 1 else {
            throw PatternShareImportSelectionError.multipleAttachments
        }
        guard supportedTypeIdentifier(
            in: registeredTypeIdentifiers[0]
        ) != nil else {
            throw PatternShareImportSelectionError.unsupported
        }
        return 0
    }

    static func supportedTypeIdentifier(
        in registeredTypeIdentifiers: [String]
    ) -> String? {
        let supportedTypes: [UTType] = [.pdf, .png, .jpeg, .heic]
        return registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return supportedTypes.contains { type.conforms(to: $0) }
        }
    }
}

public enum PatternShareImportFilename {
    public static func safeFilename(
        suggestedName: String?,
        typeIdentifier: String
    ) throws -> String {
        let fileExtension = try canonicalExtension(
            for: typeIdentifier
        )
        let candidate = (suggestedName ?? "")
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: { character in
                character == "/" || character == "\\" || character == ":"
            })
            .last
            .map(String.init) ?? ""
        let withoutControls = String(candidate.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let stem = withoutControls.isEmpty
            ? ""
            : URL(fileURLWithPath: withoutControls)
                .deletingPathExtension()
                .lastPathComponent
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: ".")
                ))
        let fallback = stem.isEmpty ? "Pattern" : stem
        let suffix = ".\(fileExtension)"
        let byteLimit = 128 - suffix.utf8.count
        var bounded = ""
        for character in fallback {
            let next = bounded + String(character)
            guard next.utf8.count <= byteLimit else { break }
            bounded = next
        }
        if bounded.isEmpty {
            bounded = "Pattern"
        }
        return bounded + suffix
    }

    public static func canonicalExtension(
        for typeIdentifier: String
    ) throws -> String {
        guard let type = UTType(typeIdentifier) else {
            throw PatternShareImportSelectionError.unsupported
        }
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .png) { return "png" }
        if type.conforms(to: .jpeg) { return "jpg" }
        if type.conforms(to: .heic) { return "heic" }
        throw PatternShareImportSelectionError.unsupported
    }
}

public struct PatternShareImportProviderSelection: Equatable, Sendable {
    public let itemIndex: Int
    public let attachmentIndex: Int
    public let typeIdentifier: String

    public static func select(
        from registeredTypeIdentifiersByItem: [[[String]]]
    ) throws -> PatternShareImportProviderSelection {
        guard !registeredTypeIdentifiersByItem.isEmpty else {
            throw PatternShareImportSelectionError.noAttachment
        }
        guard registeredTypeIdentifiersByItem.count == 1 else {
            throw PatternShareImportSelectionError.multipleAttachments
        }
        let attachments = registeredTypeIdentifiersByItem[0]
        let attachmentIndex = try PatternShareImportAttachmentSelector
            .indexOfSingleSupportedFile(in: attachments)
        guard let typeIdentifier = PatternShareImportAttachmentSelector
            .supportedTypeIdentifier(in: attachments[attachmentIndex]) else {
            throw PatternShareImportSelectionError.unsupported
        }
        return PatternShareImportProviderSelection(
            itemIndex: 0,
            attachmentIndex: attachmentIndex,
            typeIdentifier: typeIdentifier
        )
    }
}

public final class PatternShareImportCompletionGate: @unchecked Sendable {
    private enum State {
        case waiting
        case processing
        case terminal
    }

    private let lock = NSLock()
    private var state = State.waiting

    public init() {}

    public func beginProcessing() -> Bool {
        lock.withLock {
            guard state == .waiting else { return false }
            state = .processing
            return true
        }
    }

    public func finish() -> Bool {
        lock.withLock {
            guard state == .processing else { return false }
            state = .terminal
            return true
        }
    }

    public func timeout() -> Bool {
        lock.withLock {
            guard state == .waiting else { return false }
            state = .terminal
            return true
        }
    }

    public func cancel() -> Bool {
        lock.withLock {
            guard state != .terminal else { return false }
            state = .terminal
            return true
        }
    }
}

public enum PatternShareImportTerminalAction: Equatable, Sendable {
    case cancelRequest
    case completeRequest
    case none
}

public final class PatternShareImportOperationCoordinator: @unchecked Sendable {
    private let gate = PatternShareImportCompletionGate()
    public let cancellationToken = PatternInboxEnqueueCancellationToken()

    public init() {}

    public func beginProviderCallback() -> Bool {
        gate.beginProcessing()
    }

    public func finishProcessing() -> Bool {
        gate.finish()
    }

    public func timeout() -> Bool {
        guard gate.timeout() else { return false }
        _ = cancellationToken.requestCancellation()
        return true
    }

    public func cancel() -> PatternShareImportTerminalAction {
        switch cancellationToken.requestCancellation() {
        case .cancelled:
            return gate.cancel() ? .cancelRequest : .none
        case .alreadyCancelled:
            return .none
        case .committed:
            return gate.finish() ? .completeRequest : .none
        }
    }
}

public protocol PatternShareImportFileProvider: Sendable {
    var suggestedName: String? { get }
    var registeredTypeIdentifiers: [String] { get }

    func loadFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completion: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> Progress
}

public struct PatternShareImportLoadedFile: Equatable, Sendable {
    public let source: URL
    public let suggestedName: String?
    public let typeIdentifier: String

    public init(
        source: URL,
        suggestedName: String?,
        typeIdentifier: String
    ) {
        self.source = source
        self.suggestedName = suggestedName
        self.typeIdentifier = typeIdentifier
    }
}

public enum PatternShareImportProviderResult: Equatable, Sendable {
    case success
    case failure(PatternShareImportErrorMessage)
}

public final class PatternShareImportProviderSession: @unchecked Sendable {
    public typealias Processor = @Sendable (
        PatternShareImportLoadedFile,
        PatternInboxEnqueueCancellationToken
    ) throws -> Void
    public typealias Publisher = @Sendable (
        PatternShareImportProviderResult
    ) -> Void

    private let provider: any PatternShareImportFileProvider
    private let typeIdentifier: String
    private let operation: PatternShareImportOperationCoordinator
    private let process: Processor
    private let publish: Publisher
    private let lock = NSLock()
    private var progress: Progress?
    private var started = false
    private var completedResult: PatternShareImportProviderResult?
    private var terminalClaimed = false

    public init(
        provider: any PatternShareImportFileProvider,
        typeIdentifier: String,
        operation: PatternShareImportOperationCoordinator = .init(),
        process: @escaping Processor,
        publish: @escaping Publisher
    ) {
        self.provider = provider
        self.typeIdentifier = typeIdentifier
        self.operation = operation
        self.process = process
        self.publish = publish
    }

    public func start() {
        let shouldStart = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        let progress = provider.loadFileRepresentation(
            forTypeIdentifier: typeIdentifier
        ) { [weak self, provider, typeIdentifier, operation, process, publish] url, error in
            guard operation.beginProviderCallback() else { return }
            let result: PatternShareImportProviderResult
            if let error {
                result = .failure(
                    PatternShareImportErrorMapper.messageForProviderLoad(error)
                )
            } else if let url {
                do {
                    try process(
                        PatternShareImportLoadedFile(
                            source: url,
                            suggestedName: provider.suggestedName,
                            typeIdentifier: typeIdentifier
                        ),
                        operation.cancellationToken
                    )
                    result = .success
                } catch {
                    result = .failure(
                        PatternShareImportErrorMapper.message(for: error)
                    )
                }
            } else {
                result = .failure(.loadFailed)
            }
            guard operation.finishProcessing() else { return }
            self?.lock.withLock {
                self?.completedResult = result
            }
            publish(result)
        }
        lock.withLock {
            self.progress = progress
        }
    }

    public func cancel() -> PatternShareImportTerminalAction {
        var action = operation.cancel()
        if action == .none {
            action = lock.withLock {
                guard !terminalClaimed, let completedResult else {
                    return .none
                }
                terminalClaimed = true
                switch completedResult {
                case .success:
                    return .completeRequest
                case .failure:
                    return .cancelRequest
                }
            }
        }
        if action == .cancelRequest {
            lock.withLock { progress }?.cancel()
        }
        return action
    }

    public func timeout() -> Bool {
        guard operation.timeout() else { return false }
        lock.withLock { progress }?.cancel()
        return true
    }
}

public enum PatternShareImportFailure: Error, Equatable, Sendable {
    case accessDenied
    case loadFailed
    case timedOut
    case cancelled
}

public enum PatternShareImportErrorMessage: String, Equatable, Sendable {
    case unsupported = "share.error.unsupported"
    case multipleAttachments = "share.error.multiple"
    case accessDenied = "share.error.access"
    case loadFailed = "share.error.load"
    case timedOut = "share.error.timeout"
    case cancelled = "share.error.cancelled"
    case emptyFile = "share.error.empty"
    case fileTooLarge = "share.error.tooLarge"
    case invalidFile = "share.error.invalidFile"
    case storageUnavailable = "share.error.storage"
    case unexpected = "share.error.unexpected"
}

public enum PatternShareImportErrorMapper {
    public static func messageForProviderLoad(
        _ error: any Error
    ) -> PatternShareImportErrorMessage {
        message(for: error) == .accessDenied
            ? .accessDenied
            : .loadFailed
    }

    public static func message(
        for error: any Error
    ) -> PatternShareImportErrorMessage {
        if let error = error as? PatternShareImportSelectionError {
            switch error {
            case .noAttachment, .unsupported:
                return .unsupported
            case .multipleAttachments:
                return .multipleAttachments
            }
        }
        if let error = error as? PatternShareImportFailure {
            switch error {
            case .accessDenied:
                return .accessDenied
            case .loadFailed:
                return .loadFailed
            case .timedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            }
        }
        if let error = error as? PatternFileError {
            switch error {
            case .empty:
                return .emptyFile
            case .tooLarge:
                return .fileTooLarge
            case .unsupported, .invalidContent:
                return .invalidFile
            case .unsafeStoredFilename:
                return .storageUnavailable
            }
        }
        if error is PatternInboxError {
            return .storageUnavailable
        }
        if let error = error as? CocoaError,
           error.code == .fileReadNoPermission {
            return .accessDenied
        }
        return .unexpected
    }
}
