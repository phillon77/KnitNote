import Foundation

public struct StitchSearchResult: Equatable, Sendable {
    public let entryID: String
    public let repetitions: Int?

    public init(entryID: String, repetitions: Int?) {
        self.entryID = entryID
        self.repetitions = repetitions
    }
}

public enum StitchSearch {
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    public static func results(query: String, category: StitchCategory?,
                               in catalog: StitchCatalog) -> [StitchSearchResult] {
        let query = normalize(query)
        let indexed = catalog.entries.map { entry in
            (entry: entry, terms: (Array(entry.names.values) + entry.aliases).map(normalize))
        }
        // A recorded complete abbreviation wins over interpreting its digits as a count.
        let hasExactMatch = indexed.contains { $0.terms.contains(query) }
        if !hasExactMatch, let counted = countedInstruction(query) {
            guard let entry = catalog.entry(id: counted.entryID),
                  category == nil || entry.category == category else { return [] }
            return [counted]
        }
        let ranked = indexed.compactMap { item -> (entry: StitchEntry, rank: Int)? in
            guard category == nil || item.entry.category == category else { return nil }
            if query.isEmpty { return (item.entry, 0) }
            let rank = item.terms.compactMap { term -> Int? in
                if term == query { return 0 }
                if term.hasPrefix(query) { return 1 }
                if term.contains(query) { return 2 }
                return nil
            }.min()
            return rank.map { (item.entry, $0) }
        }.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.entry.order != $1.entry.order { return $0.entry.order < $1.entry.order }
            return $0.entry.id < $1.entry.id
        }
        var seen: Set<String> = []
        return ranked.compactMap { item in
            guard seen.insert(item.entry.id).inserted else { return nil }
            return StitchSearchResult(entryID: item.entry.id, repetitions: nil)
        }
    }

    private static func countedInstruction(_ query: String) -> StitchSearchResult? {
        guard let initial = query.first, initial == "k" || initial == "p" else { return nil }
        let digits = query.dropFirst().drop(while: { $0.isWhitespace })
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let count = Int(digits), count > 0 else { return nil }
        return StitchSearchResult(entryID: initial == "k" ? "knit" : "purl", repetitions: count)
    }
}
