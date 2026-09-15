import Foundation

public enum StitchCatalogError: Error, Equatable, Sendable {
    case missingResource
    case unsupportedVersion(Int)
    case duplicateID(String)
    case invalidEntry(String)
    case missingReference(String)
}

/// Versioned, read-only stitch data. IDs remain stable across interface languages.
public struct StitchCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sources: [StitchSource]
    public let entries: [StitchEntry]

    public init(schemaVersion: Int, sources: [StitchSource], entries: [StitchEntry]) {
        self.schemaVersion = schemaVersion
        self.sources = sources
        self.entries = entries
    }

    public func entry(id: String) -> StitchEntry? {
        entries.first { $0.id == id }
    }

    public static func decode(_ data: Data) throws -> StitchCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validateContents()
        return catalog
    }

    public static func bundled() throws -> StitchCatalog {
        guard let url = StitchDictionaryResources.url(named: "stitch-dictionary-v1") else {
            throw StitchCatalogError.missingResource
        }
        let catalog = try decode(Data(contentsOf: url))
        let diagrams = try StitchDiagram.loadBundled()
        try requireUnique(diagrams.map(\.id))
        try catalog.validateExternalReferences(diagramIDs: Set(diagrams.map(\.id)), localizedKeys: nil)
        return catalog
    }

    /// Callers provide the actual diagram and localization inventories for their bundle.
    public func validate(diagramIDs: Set<String>, localizedKeys: Set<String>) throws {
        try validateContents()
        try validateExternalReferences(diagramIDs: diagramIDs, localizedKeys: localizedKeys)
    }

    private func validateContents() throws {
        guard schemaVersion == 1 else { throw StitchCatalogError.unsupportedVersion(schemaVersion) }
        try Self.requireUnique(sources.map(\.id))
        try Self.requireUnique(entries.map(\.id))
        try Self.requireUnique(entries.flatMap { $0.symbols.map(\.id) })
        let sourceIDs = Set(sources.map(\.id))
        let entryIDs = Set(entries.map(\.id))
        for source in sources {
            guard Self.hasText(source.id), Self.hasText(source.title), Self.hasText(source.scope),
                  source.url.scheme?.lowercased() == "https", source.url.host?.isEmpty == false,
                  Self.isCalendarDate(source.checkedOn) else {
                throw StitchCatalogError.invalidEntry(source.id)
            }
        }
        for entry in entries {
            guard Self.hasText(entry.id), !entry.steps.isEmpty,
                  entry.consumes >= 0, entry.produces >= 0,
                  ["zh-Hant", "zh-Hans", "en", "ja", "ko"].allSatisfy({ Self.hasText(entry.names[$0] ?? "") }),
                  textKeys(for: entry).allSatisfy(Self.hasText),
                  entry.steps.allSatisfy({ Self.hasText($0.diagramID) }),
                  entry.symbols.allSatisfy({ Self.hasText($0.id) && Self.hasText($0.diagramID) }) else {
                throw StitchCatalogError.invalidEntry(entry.id)
            }
            if let notation = entry.displayNotation {
                guard Self.hasText(notation), entry.aliases.contains(where: {
                    $0.lowercased() == notation.lowercased()
                }) else { throw StitchCatalogError.invalidEntry(entry.id) }
            }
            try Self.requireReferences(entry.relatedIDs, in: entryIDs)
            try Self.requireReferences(entry.sourceIDs, in: sourceIDs)
            for symbol in entry.symbols { try Self.requireReferences(symbol.sourceIDs, in: sourceIDs) }
        }
    }

    private func validateExternalReferences(diagramIDs: Set<String>, localizedKeys: Set<String>?) throws {
        for entry in entries {
            try Self.requireReferences(entry.steps.map(\.diagramID) + entry.symbols.map(\.diagramID), in: diagramIDs)
            if let localizedKeys { try Self.requireReferences(textKeys(for: entry), in: localizedKeys) }
        }
    }

    private func textKeys(for entry: StitchEntry) -> [String] {
        [entry.titleKey, entry.summaryKey] + entry.noteKeys
        + entry.steps.flatMap { [$0.textKey, $0.accessibilityKey] }
        + entry.symbols.flatMap { [$0.traditionKey, $0.conditionKey] }
    }

    private static func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func requireUnique(_ ids: [String]) throws {
        var seen: Set<String> = []
        for id in ids where !seen.insert(id).inserted { throw StitchCatalogError.duplicateID(id) }
    }

    private static func requireReferences(_ ids: [String], in inventory: Set<String>) throws {
        for id in ids where !inventory.contains(id) { throw StitchCatalogError.missingReference(id) }
    }

    private static func isCalendarDate(_ value: String) -> Bool {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return false }
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, pieces[0] > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let requested = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
        guard let date = calendar.date(from: requested) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == requested.year && actual.month == requested.month && actual.day == requested.day
    }
}
