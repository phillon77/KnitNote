import Foundation

/// Identifies whether a pattern is being read independently or through one
/// specific project usage. Reader writes must always use `usageID`, never the
/// pattern ID, because a pattern can be linked to more than one project.
public struct PatternReaderContext: Equatable, Hashable, Sendable {
    public let patternID: UUID
    public let usageID: UUID?
    public let projectID: UUID?
    public let projectIsCompleted: Bool

    private init(
        patternID: UUID,
        usageID: UUID?,
        projectID: UUID?,
        projectIsCompleted: Bool
    ) {
        self.patternID = patternID
        self.usageID = usageID
        self.projectID = projectID
        self.projectIsCompleted = projectIsCompleted
    }

    public static func readOnly(patternID: UUID) -> Self {
        .init(
            patternID: patternID,
            usageID: nil,
            projectID: nil,
            projectIsCompleted: false
        )
    }

    public static func project(
        patternID: UUID,
        usageID: UUID,
        projectID: UUID,
        projectIsCompleted: Bool
    ) -> Self {
        .init(
            patternID: patternID,
            usageID: usageID,
            projectID: projectID,
            projectIsCompleted: projectIsCompleted
        )
    }

    public var canWrite: Bool {
        usageID != nil && projectID != nil && !projectIsCompleted
    }
}

/// Keeps reader content out of platform representables until the exact saved
/// state for its current context has been resolved.
public struct PatternReaderSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case hydrated
    }

    public private(set) var context: PatternReaderContext
    public private(set) var phase: Phase
    public private(set) var readingState: PatternReadingState?

    public init(context: PatternReaderContext) {
        self.context = context
        phase = .loading
        readingState = nil
    }

    public var canAcceptCanvasCallbacks: Bool {
        phase == .hydrated
    }

    public var canPersist: Bool {
        canAcceptCanvasCallbacks && context.canWrite
    }

    public mutating func beginLoading(context: PatternReaderContext) {
        self.context = context
        phase = .loading
        readingState = nil
    }

    public mutating func hydrate(readingState: PatternReadingState) {
        self.readingState = readingState
        phase = .hydrated
    }

    @discardableResult
    public mutating func acceptCanvasState(_ state: PatternReadingState) -> Bool {
        guard canAcceptCanvasCallbacks else { return false }
        readingState = state
        return true
    }
}

public enum PatternReaderCounterAccessibilityPolicy: Sendable {
    public static func canExposeIncrementAction(isEnabled: Bool) -> Bool {
        isEnabled
    }

    public static func canExposeManageAction(isEnabled: Bool) -> Bool {
        isEnabled
    }
}
