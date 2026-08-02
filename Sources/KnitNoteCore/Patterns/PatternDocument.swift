import Foundation
public enum PatternKind: String, Codable, Sendable { case image, pdf }
public enum HighlightMode: String, Codable, CaseIterable, Sendable { case horizontal, vertical, cross }
public enum PatternReaderPresentation: Sendable { case sheet, fullScreen }
public func patternReaderPresentation(isPad: Bool) -> PatternReaderPresentation { .fullScreen }
public struct PatternPageState: Codable, Hashable, Sendable {
    public var horizontalPosition: Double
    public var verticalPosition: Double
    public var offsetX: Double
    public var offsetY: Double
    public var note: String?
    public init(
        horizontalPosition: Double = 0.5,
        verticalPosition: Double = 0.5,
        offsetX: Double = 0,
        offsetY: Double = 0,
        note: String? = nil
    ) {
        self.horizontalPosition = min(1, max(0, horizontalPosition))
        self.verticalPosition = min(1, max(0, verticalPosition))
        self.offsetX = min(1, max(0, offsetX))
        self.offsetY = min(1, max(0, offsetY))
        let clean = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.note = clean.isEmpty ? nil : clean
    }

    private enum CodingKeys: String, CodingKey {
        case horizontalPosition
        case verticalPosition
        case offsetX
        case offsetY
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            horizontalPosition: try container.decodeIfPresent(Double.self, forKey: .horizontalPosition) ?? 0.5,
            verticalPosition: try container.decodeIfPresent(Double.self, forKey: .verticalPosition) ?? 0.5,
            offsetX: try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0,
            offsetY: try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0,
            note: try container.decodeIfPresent(String.self, forKey: .note)
        )
    }
}
public struct PatternDocument: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID; public var displayName: String; public let kind: PatternKind; public let storedFilename: String
    public let createdAt: Date; public var lastOpenedAt: Date?; public var pageIndex: Int
    public var zoomScale: Double; public var contentOffsetX: Double; public var contentOffsetY: Double
    public var highlightEnabled: Bool; public var highlightPosition: Double; public var highlightMode: HighlightMode; public var verticalHighlightPosition: Double
    public var pageStates: [Int: PatternPageState]
    public init(id: UUID = UUID(), displayName: String, kind: PatternKind, storedFilename: String, createdAt: Date = .now) {
        self.id=id; self.displayName=displayName; self.kind=kind; self.storedFilename=storedFilename; self.createdAt=createdAt
        pageIndex=0; zoomScale=1; contentOffsetX=0; contentOffsetY=0; highlightEnabled=false; highlightPosition=0.5; highlightMode = .horizontal; verticalHighlightPosition = 0.5; pageStates = [:]
    }

    enum CodingKeys: String, CodingKey { case id, displayName, kind, storedFilename, createdAt, lastOpenedAt, pageIndex, zoomScale, contentOffsetX, contentOffsetY, highlightEnabled, highlightPosition, highlightMode, verticalHighlightPosition, pageStates }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); displayName = try c.decode(String.self, forKey: .displayName)
        kind = try c.decode(PatternKind.self, forKey: .kind); storedFilename = try c.decode(String.self, forKey: .storedFilename)
        createdAt = try c.decode(Date.self, forKey: .createdAt); lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        pageIndex = max(0, try c.decodeIfPresent(Int.self, forKey: .pageIndex) ?? 0); zoomScale = max(0.1, try c.decodeIfPresent(Double.self, forKey: .zoomScale) ?? 1)
        contentOffsetX = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .contentOffsetX) ?? 0)); contentOffsetY = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .contentOffsetY) ?? 0))
        highlightEnabled = try c.decodeIfPresent(Bool.self, forKey: .highlightEnabled) ?? false
        highlightPosition = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .highlightPosition) ?? 0.5))
        highlightMode = try c.decodeIfPresent(HighlightMode.self, forKey: .highlightMode) ?? .horizontal
        verticalHighlightPosition = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .verticalHighlightPosition) ?? 0.5))
        if let saved = try c.decodeIfPresent([Int: PatternPageState].self, forKey: .pageStates) {
            pageStates = saved
        } else {
            pageStates = [pageIndex: PatternPageState(horizontalPosition: highlightPosition, verticalPosition: verticalHighlightPosition)]
        }
    }

    public mutating func setPageNote(_ text: String, pageIndex: Int) {
        let cleanPageIndex = max(0, pageIndex)
        let existing = pageStates[cleanPageIndex]
        let horizontal = existing?.horizontalPosition ?? (cleanPageIndex == self.pageIndex ? highlightPosition : 0.5)
        let vertical = existing?.verticalPosition ?? (cleanPageIndex == self.pageIndex ? verticalHighlightPosition : 0.5)
        let offsetX = existing?.offsetX ?? (cleanPageIndex == self.pageIndex ? contentOffsetX : 0)
        let offsetY = existing?.offsetY ?? (cleanPageIndex == self.pageIndex ? contentOffsetY : 0)
        pageStates[cleanPageIndex] = PatternPageState(
            horizontalPosition: horizontal,
            verticalPosition: vertical,
            offsetX: offsetX,
            offsetY: offsetY,
            note: text
        )
    }
}

public struct PatternReadingState: Codable, Equatable, Hashable, Sendable {
    public var pageIndex: Int
    public var pdfWidthScaleRatio: Double
    public var zoomScale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var highlightEnabled: Bool
    public var highlightPosition: Double
    public var highlightMode: HighlightMode
    public var verticalHighlightPosition: Double
    public var pageNote: String
    public var pageStates: [Int: PatternPageState]
    public init(pageIndex: Int = 0, pdfWidthScaleRatio: Double = PatternPDFScalePolicy.defaultRatio, zoomScale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, highlightEnabled: Bool = false, highlightPosition: Double = 0.5, highlightMode: HighlightMode = .horizontal, verticalHighlightPosition: Double = 0.5, pageNote: String = "", pageStates: [Int: PatternPageState] = [:]) {
        self.pageIndex = max(0, pageIndex); self.pdfWidthScaleRatio = PatternPDFScalePolicy.normalizedRatio(pdfWidthScaleRatio); self.zoomScale = max(0.1, zoomScale)
        self.offsetX = min(1, max(0, offsetX)); self.offsetY = min(1, max(0, offsetY)); self.highlightEnabled = highlightEnabled
        self.highlightPosition = min(1, max(0, highlightPosition)); self.highlightMode = highlightMode
        self.verticalHighlightPosition = min(1, max(0, verticalHighlightPosition))
        self.pageNote = pageNote
        self.pageStates = pageStates
    }

    enum CodingKeys: String, CodingKey {
        case pageIndex
        case pdfWidthScaleRatio
        case zoomScale
        case offsetX
        case offsetY
        case highlightEnabled
        case highlightPosition
        case highlightMode
        case verticalHighlightPosition
        case pageNote
        case pageStates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = max(0, try container.decodeIfPresent(Int.self, forKey: .pageIndex) ?? 0)
        pdfWidthScaleRatio = PatternPDFScalePolicy.normalizedRatio(
            try container.decodeIfPresent(Double.self, forKey: .pdfWidthScaleRatio) ?? PatternPDFScalePolicy.defaultRatio
        )
        zoomScale = max(0.1, try container.decodeIfPresent(Double.self, forKey: .zoomScale) ?? 1)
        offsetX = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0))
        offsetY = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0))
        highlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .highlightEnabled) ?? false
        highlightPosition = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .highlightPosition) ?? 0.5))
        highlightMode = try container.decodeIfPresent(HighlightMode.self, forKey: .highlightMode) ?? .horizontal
        verticalHighlightPosition = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .verticalHighlightPosition) ?? 0.5))
        pageNote = try container.decodeIfPresent(String.self, forKey: .pageNote) ?? ""
        pageStates = try container.decodeIfPresent([Int: PatternPageState].self, forKey: .pageStates) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(PatternPDFScalePolicy.normalizedRatio(pdfWidthScaleRatio), forKey: .pdfWidthScaleRatio)
        try container.encode(zoomScale, forKey: .zoomScale)
        try container.encode(offsetX, forKey: .offsetX)
        try container.encode(offsetY, forKey: .offsetY)
        try container.encode(highlightEnabled, forKey: .highlightEnabled)
        try container.encode(highlightPosition, forKey: .highlightPosition)
        try container.encode(highlightMode, forKey: .highlightMode)
        try container.encode(verticalHighlightPosition, forKey: .verticalHighlightPosition)
        try container.encode(pageNote, forKey: .pageNote)
        try container.encode(pageStates, forKey: .pageStates)
    }

    public func pdfRestorePageIndex(pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(pageIndex, pageCount - 1)
    }

    public mutating func setPDFAnchor(pageIndex: Int, offsetX: Double, offsetY: Double) {
        self.pageIndex = max(0, pageIndex)
        self.offsetX = min(1, max(0, offsetX))
        self.offsetY = min(1, max(0, offsetY))
        saveCurrentPage()
    }

    public mutating func movePDFPage(by delta: Int, pageCount: Int) {
        guard pageCount > 0 else { return }
        let target = min(pageCount - 1, max(0, pageIndex + delta))
        guard target != pageIndex else { return }
        saveCurrentPage()
        loadPage(target)
    }

    public mutating func transitionToPDFPage(_ target: Int) {
        let cleanTarget = max(0, target)
        guard cleanTarget != pageIndex else { return }
        saveCurrentPage()
        loadPage(cleanTarget)
    }

    @discardableResult
    public mutating func synchronizeVisiblePDFPage(_ target: Int) -> Bool {
        var updated = self
        updated.transitionToPDFPage(target)
        guard updated != self else { return false }
        self = updated
        return true
    }

    public mutating func saveCurrentPage() {
        pageStates[pageIndex] = PatternPageState(
            horizontalPosition: highlightPosition,
            verticalPosition: verticalHighlightPosition,
            offsetX: offsetX,
            offsetY: offsetY,
            note: pageNote
        )
        pageNote = pageStates[pageIndex]?.note ?? ""
    }

    public mutating func setPageNote(_ text: String) {
        pageNote = text
        saveCurrentPage()
    }

    public mutating func loadPage(_ index: Int) {
        pageIndex = max(0, index)
        let saved = pageStates[pageIndex] ?? PatternPageState()
        offsetX = saved.offsetX
        offsetY = saved.offsetY
        highlightPosition = saved.horizontalPosition
        verticalHighlightPosition = saved.verticalPosition
        pageNote = saved.note ?? ""
    }
}

public struct PatternPageReadingPosition: Equatable, Hashable, Sendable {
    public let offsetX: Double
    public let offsetY: Double

    public init(offsetX: Double = 0, offsetY: Double = 0) {
        self.offsetX = min(1, max(0, offsetX))
        self.offsetY = min(1, max(0, offsetY))
    }
}

public struct PatternBrowsingState: Equatable, Hashable, Sendable {
    public let pageIndex: Int
    public let pdfWidthScaleRatio: Double
    public let zoomScale: Double
    public let offsetX: Double
    public let offsetY: Double
    public let pageOffsets: [Int: PatternPageReadingPosition]

    public init(
        pageIndex: Int,
        pdfWidthScaleRatio: Double = PatternPDFScalePolicy.defaultRatio,
        zoomScale: Double,
        offsetX: Double,
        offsetY: Double,
        pageOffsets: [Int: PatternPageReadingPosition] = [:]
    ) {
        self.pageIndex = max(0, pageIndex)
        self.pdfWidthScaleRatio = PatternPDFScalePolicy.normalizedRatio(pdfWidthScaleRatio)
        self.zoomScale = max(0.1, zoomScale)
        self.offsetX = min(1, max(0, offsetX))
        self.offsetY = min(1, max(0, offsetY))
        self.pageOffsets = pageOffsets
    }

    public init(readingState: PatternReadingState) {
        self.init(
            pageIndex: readingState.pageIndex,
            pdfWidthScaleRatio: readingState.pdfWidthScaleRatio,
            zoomScale: readingState.zoomScale,
            offsetX: readingState.offsetX,
            offsetY: readingState.offsetY,
            pageOffsets: readingState.pageStates.mapValues {
                PatternPageReadingPosition(offsetX: $0.offsetX, offsetY: $0.offsetY)
            }
        )
    }
}

public extension PatternReadingState {
    var browsingState: PatternBrowsingState {
        PatternBrowsingState(readingState: self)
    }

    mutating func applyBrowsingState(_ browsingState: PatternBrowsingState) {
        pageIndex = browsingState.pageIndex
        pdfWidthScaleRatio = browsingState.pdfWidthScaleRatio
        zoomScale = browsingState.zoomScale
        offsetX = browsingState.offsetX
        offsetY = browsingState.offsetY
        for (pageIndex, position) in browsingState.pageOffsets {
            let existing = pageStates[pageIndex] ?? PatternPageState()
            pageStates[pageIndex] = PatternPageState(
                horizontalPosition: existing.horizontalPosition,
                verticalPosition: existing.verticalPosition,
                offsetX: position.offsetX,
                offsetY: position.offsetY,
                note: existing.note
            )
        }
    }

    func projectedForDisplay() -> PatternReadingState {
        let pageState = pageStates[pageIndex] ?? PatternPageState()
        var projected = self
        projected.highlightPosition = pageState.horizontalPosition
        projected.verticalHighlightPosition = pageState.verticalPosition
        projected.pageNote = pageState.note ?? ""
        return projected
    }
}

/// Preserves the exact reader state before a platform PDF callback changes
/// pages. A failed markup save must roll back the whole state, not only the
/// page number, because the callback has already loaded the target page's
/// highlight positions and note.
public struct PatternReaderPageTransition: Equatable, Sendable {
    public let rollbackState: PatternReadingState
    public let targetPageIndex: Int

    public var rollbackPageIndex: Int {
        rollbackState.pageIndex
    }

    public init?(previousState: PatternReadingState, proposedState: PatternReadingState) {
        guard previousState.pageIndex != proposedState.pageIndex else { return nil }
        rollbackState = previousState
        targetPageIndex = proposedState.pageIndex
    }
}

public struct PatternReadingRestoreGate: Sendable {
    public private(set) var canSample = false
    private var isRestoring = false
    public init() {}
    public mutating func beginRestoring() -> Bool {
        guard !isRestoring, !canSample else { return false }
        isRestoring = true
        return true
    }
    public mutating func didRestore() { canSample = true }
}

public struct PatternPDFPageRequestGate: Sendable {
    public private(set) var requestedPageIndex: Int?
    public init() {}

    public mutating func request(_ pageIndex: Int) {
        requestedPageIndex = max(0, pageIndex)
    }

    public mutating func accepts(_ pageIndex: Int) -> Bool {
        guard let requestedPageIndex else { return true }
        guard pageIndex == requestedPageIndex else { return false }
        self.requestedPageIndex = nil
        return true
    }
}

public extension PatternDocument {
    var readingState: PatternReadingState {
        let pageState = pageStates[pageIndex] ?? PatternPageState()
        return .init(pageIndex: pageIndex, zoomScale: zoomScale, offsetX: contentOffsetX, offsetY: contentOffsetY, highlightEnabled: highlightEnabled, highlightPosition: pageState.horizontalPosition, highlightMode: highlightMode, verticalHighlightPosition: pageState.verticalPosition, pageNote: pageState.note ?? "", pageStates: pageStates)
    }
}
