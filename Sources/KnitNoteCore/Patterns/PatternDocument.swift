import Foundation
public enum PatternKind: String, Codable, Sendable { case image, pdf }
public enum HighlightMode: String, Codable, CaseIterable, Sendable { case horizontal, vertical, cross }
public enum PatternReaderLayout: Sendable { case standard, maximizedSafe }
public func patternReaderLayout(isPad: Bool) -> PatternReaderLayout { isPad ? .maximizedSafe : .standard }
public struct PatternPageState: Codable, Hashable, Sendable {
    public var horizontalPosition: Double
    public var verticalPosition: Double
    public var note: String?
    public init(horizontalPosition: Double = 0.5, verticalPosition: Double = 0.5, note: String? = nil) {
        self.horizontalPosition = min(1, max(0, horizontalPosition))
        self.verticalPosition = min(1, max(0, verticalPosition))
        let clean = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.note = clean.isEmpty ? nil : clean
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
        pageStates[cleanPageIndex] = PatternPageState(horizontalPosition: horizontal, verticalPosition: vertical, note: text)
    }
}

public struct PatternReadingState: Equatable, Sendable {
    public var pageIndex: Int
    public var zoomScale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var highlightEnabled: Bool
    public var highlightPosition: Double
    public var highlightMode: HighlightMode
    public var verticalHighlightPosition: Double
    public var pageNote: String
    public var pageStates: [Int: PatternPageState]
    public init(pageIndex: Int = 0, zoomScale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, highlightEnabled: Bool = false, highlightPosition: Double = 0.5, highlightMode: HighlightMode = .horizontal, verticalHighlightPosition: Double = 0.5, pageNote: String = "", pageStates: [Int: PatternPageState] = [:]) {
        self.pageIndex = max(0, pageIndex); self.zoomScale = max(0.1, zoomScale)
        self.offsetX = min(1, max(0, offsetX)); self.offsetY = min(1, max(0, offsetY)); self.highlightEnabled = highlightEnabled
        self.highlightPosition = min(1, max(0, highlightPosition)); self.highlightMode = highlightMode
        self.verticalHighlightPosition = min(1, max(0, verticalHighlightPosition))
        self.pageNote = pageNote
        self.pageStates = pageStates
    }

    public func pdfRestorePageIndex(pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(pageIndex, pageCount - 1)
    }

    public mutating func movePDFPage(by delta: Int, pageCount: Int) {
        guard pageCount > 0 else { return }
        let target = min(pageCount - 1, max(0, pageIndex + delta))
        guard target != pageIndex else { return }
        saveCurrentPage()
        offsetX = 0
        offsetY = 0
        loadPage(target)
    }

    public mutating func transitionToPDFPage(_ target: Int) {
        let cleanTarget = max(0, target)
        guard cleanTarget != pageIndex else { return }
        saveCurrentPage()
        offsetX = 0
        offsetY = 0
        loadPage(cleanTarget)
    }

    public mutating func saveCurrentPage() {
        pageStates[pageIndex] = PatternPageState(horizontalPosition: highlightPosition, verticalPosition: verticalHighlightPosition, note: pageNote)
        pageNote = pageStates[pageIndex]?.note ?? ""
    }

    public mutating func setPageNote(_ text: String) {
        pageNote = text
        saveCurrentPage()
    }

    public mutating func loadPage(_ index: Int) {
        pageIndex = max(0, index)
        let saved = pageStates[pageIndex] ?? PatternPageState()
        highlightPosition = saved.horizontalPosition
        verticalHighlightPosition = saved.verticalPosition
        pageNote = saved.note ?? ""
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
        .init(pageIndex: pageIndex, zoomScale: zoomScale, offsetX: contentOffsetX, offsetY: contentOffsetY, highlightEnabled: highlightEnabled, highlightPosition: pageStates[pageIndex]?.horizontalPosition ?? highlightPosition, highlightMode: highlightMode, verticalHighlightPosition: pageStates[pageIndex]?.verticalPosition ?? verticalHighlightPosition, pageNote: pageStates[pageIndex]?.note ?? "", pageStates: pageStates)
    }
}
