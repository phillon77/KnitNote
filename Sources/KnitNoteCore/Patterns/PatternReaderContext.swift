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

/// The values which must change the platform reader instance whenever its
/// source changes. The asset and completion state are included because either
/// can change without changing a usage ID.
public struct PatternReaderContextIdentity: Hashable, Sendable {
    public let patternID: UUID
    public let usageID: UUID?
    public let projectID: UUID?
    public let assetID: UUID?
    public let projectIsCompleted: Bool

    public init(context: PatternReaderContext, assetID: UUID?) {
        patternID = context.patternID
        usageID = context.usageID
        projectID = context.projectID
        self.assetID = assetID
        projectIsCompleted = context.projectIsCompleted
    }
}

/// Resolves only the state owned by the requested usage; similar usages must
/// never leak their reader state into a newly presented reader.
public enum PatternReaderStateLoader: Sendable {
    public static func readingState(
        for context: PatternReaderContext,
        usages: [PatternProjectUsage]
    ) -> PatternReadingState {
        guard let usageID = context.usageID,
              let projectID = context.projectID,
              let usage = usages.first(where: {
                  $0.id == usageID && $0.patternID == context.patternID && $0.projectID == projectID
              }) else {
            return .init()
        }
        return usage.readingState
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
    public private(set) var identity: PatternReaderContextIdentity
    public private(set) var generation: UInt64
    public private(set) var phase: Phase
    public private(set) var readingState: PatternReadingState?

    public init(context: PatternReaderContext) {
        self.context = context
        identity = .init(context: context, assetID: nil)
        generation = 0
        phase = .loading
        readingState = nil
    }

    public var canAcceptCanvasCallbacks: Bool {
        phase == .hydrated
    }

    public var canPersist: Bool {
        canAcceptCanvasCallbacks && context.canWrite
    }

    @discardableResult
    public mutating func beginLoading(
        context: PatternReaderContext,
        identity: PatternReaderContextIdentity
    ) -> UInt64 {
        self.context = context
        self.identity = identity
        generation &+= 1
        phase = .loading
        readingState = nil
        return generation
    }

    public mutating func beginLoading(context: PatternReaderContext) {
        _ = beginLoading(context: context, identity: .init(context: context, assetID: nil))
    }

    @discardableResult
    public mutating func hydrate(_ readingState: PatternReadingState, for generation: UInt64) -> Bool {
        guard self.generation == generation, phase == .loading else { return false }
        self.readingState = readingState
        phase = .hydrated
        return true
    }

    public mutating func hydrate(readingState: PatternReadingState) {
        _ = hydrate(readingState, for: generation)
    }

    @discardableResult
    public mutating func acceptCanvasState(_ state: PatternReadingState) -> Bool {
        guard canAcceptCanvasCallbacks else { return false }
        readingState = state
        return true
    }
}

/// Tracks whether markup was loaded successfully for the active reader page.
/// A decoding or safety error is deliberately non-persistable, so lifecycle
/// saves cannot replace unreadable bytes with an empty document.
public struct PatternReaderMarkupSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed
    }

    public private(set) var phase: Phase = .loading
    public private(set) var readerGeneration: UInt64 = 0
    public private(set) var pageIndex: Int = 0
    public private(set) var isDirty = false
    private var loadedDocument: PatternMarkupDocument?

    public init() {}

    public mutating func beginLoading(readerGeneration: UInt64, pageIndex: Int) {
        self.readerGeneration = readerGeneration
        self.pageIndex = pageIndex
        phase = .loading
        isDirty = false
        loadedDocument = nil
    }

    @discardableResult
    public mutating func finishLoading(
        _ document: PatternMarkupDocument,
        for readerGeneration: UInt64,
        pageIndex: Int
    ) -> Bool {
        guard matches(readerGeneration: readerGeneration, pageIndex: pageIndex), phase == .loading else {
            return false
        }
        phase = .loaded
        loadedDocument = document
        return true
    }

    @discardableResult
    public mutating func failLoading(for readerGeneration: UInt64, pageIndex: Int) -> Bool {
        guard matches(readerGeneration: readerGeneration, pageIndex: pageIndex), phase == .loading else {
            return false
        }
        phase = .failed
        return true
    }

    public mutating func recordEdit(_ document: PatternMarkupDocument) {
        guard phase == .loaded, document != loadedDocument else { return }
        isDirty = true
    }

    public func canPersistMarkup(readerGeneration: UInt64, pageIndex: Int) -> Bool {
        matches(readerGeneration: readerGeneration, pageIndex: pageIndex) && phase == .loaded && isDirty
    }

    public mutating func markPersisted(readerGeneration: UInt64, pageIndex: Int) {
        guard matches(readerGeneration: readerGeneration, pageIndex: pageIndex), phase == .loaded else { return }
        isDirty = false
        loadedDocument = nil
    }

    private func matches(readerGeneration: UInt64, pageIndex: Int) -> Bool {
        self.readerGeneration == readerGeneration && self.pageIndex == pageIndex
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
