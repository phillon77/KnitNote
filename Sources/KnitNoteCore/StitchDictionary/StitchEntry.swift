import Foundation

public enum StitchCategory: String, Codable, CaseIterable, Sendable {
    case basic, increase, decrease, cable
}

public struct StitchSource: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let checkedOn: String
    public let scope: String

    public init(id: String, title: String, url: URL, checkedOn: String, scope: String) {
        self.id = id
        self.title = title
        self.url = url
        self.checkedOn = checkedOn
        self.scope = scope
    }
}

public struct StitchStep: Codable, Equatable, Sendable {
    public let textKey: String
    public let diagramID: String
    public let accessibilityKey: String

    public init(textKey: String, diagramID: String, accessibilityKey: String) {
        self.textKey = textKey
        self.diagramID = diagramID
        self.accessibilityKey = accessibilityKey
    }
}

public struct StitchSymbol: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let diagramID: String
    public let traditionKey: String
    public let conditionKey: String
    public let sourceIDs: [String]

    public init(id: String, diagramID: String, traditionKey: String,
                conditionKey: String, sourceIDs: [String]) {
        self.id = id
        self.diagramID = diagramID
        self.traditionKey = traditionKey
        self.conditionKey = conditionKey
        self.sourceIDs = sourceIDs
    }
}

public struct StitchEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let category: StitchCategory
    public let order: Int
    public let names: [String: String]
    public let aliases: [String]
    public let titleKey: String
    public let summaryKey: String
    public let steps: [StitchStep]
    public let consumes: Int
    public let produces: Int
    public let noteKeys: [String]
    public let relatedIDs: [String]
    public let sourceIDs: [String]
    public let symbols: [StitchSymbol]

    public init(id: String, category: StitchCategory, order: Int, names: [String: String],
                aliases: [String], titleKey: String, summaryKey: String, steps: [StitchStep],
                consumes: Int, produces: Int, noteKeys: [String], relatedIDs: [String],
                sourceIDs: [String], symbols: [StitchSymbol]) {
        self.id = id
        self.category = category
        self.order = order
        self.names = names
        self.aliases = aliases
        self.titleKey = titleKey
        self.summaryKey = summaryKey
        self.steps = steps
        self.consumes = consumes
        self.produces = produces
        self.noteKeys = noteKeys
        self.relatedIDs = relatedIDs
        self.sourceIDs = sourceIDs
        self.symbols = symbols
    }
}
