public enum PatternPageThumbnailPolicy {
    public static func shouldShow(kind: PatternKind, pageCount: Int, markupMode: Bool) -> Bool {
        kind == .pdf && pageCount > 1 && !markupMode
    }

    public static func preloadIndices(pageCount: Int, currentPage: Int) -> [Int] {
        guard pageCount > 1, currentPage >= 0, currentPage < pageCount else { return [] }
        return Array(max(0, currentPage - 1)...min(pageCount - 1, currentPage + 1))
    }
}
