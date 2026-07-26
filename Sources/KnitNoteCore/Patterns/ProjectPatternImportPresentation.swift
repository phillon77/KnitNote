import Foundation

public struct ProjectPatternImportOperationCoordinator: Equatable, Sendable {
    public private(set) var currentOperationID: UUID?

    public var isRunning: Bool {
        currentOperationID != nil
    }

    public init() {}

    @discardableResult
    public mutating func begin(id: UUID = UUID()) -> UUID {
        currentOperationID = id
        return id
    }

    public func isCurrent(_ id: UUID) -> Bool {
        currentOperationID == id
    }

    @discardableResult
    public mutating func finishIfCurrent(_ id: UUID) -> Bool {
        guard isCurrent(id) else { return false }
        currentOperationID = nil
        return true
    }

    public mutating func cancel() {
        currentOperationID = nil
    }
}

public enum ProjectPatternImportFailureContext: Equatable, Sendable {
    case filePicker
    case operation
}

public enum ProjectPatternImportErrorMessage: String, Equatable, Sendable {
    case emptyFile = "patterns.import.error.empty"
    case fileTooLarge = "patterns.import.error.tooLarge"
    case invalidFile = "patterns.import.error.invalidFile"
    case storageUnavailable = "patterns.import.error.storage"
    case projectUnavailable = "patterns.import.error.projectUnavailable"
    case cancelled = "patterns.import.error.cancelled"
    case fileSelectionFailed = "patterns.import.error.fileSelection"
    case unexpected = "patterns.import.error.unexpected"
}

public enum ProjectPatternImportErrorMapper {
    public static func message(
        for error: any Error,
        context: ProjectPatternImportFailureContext = .operation
    ) -> ProjectPatternImportErrorMessage {
        if error is CancellationError {
            return .cancelled
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
        if let error = error as? PatternLibraryMutationError {
            switch error {
            case .projectNotFound:
                return .projectUnavailable
            case .patternNotFound, .usageNotFound, .usageInactive,
                 .projectCompleted, .activeLinksExist:
                return .storageUnavailable
            }
        }
        if error is ProjectStoreError {
            return .storageUnavailable
        }
        return context == .filePicker ? .fileSelectionFailed : .unexpected
    }
}
