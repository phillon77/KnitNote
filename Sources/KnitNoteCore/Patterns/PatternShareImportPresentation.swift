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
