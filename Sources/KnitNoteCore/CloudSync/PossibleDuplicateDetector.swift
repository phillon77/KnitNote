import Foundation

/// A suggestion only: matching names never merge identities or remove content.
public struct PossibleDuplicate: Equatable, Sendable {
    public let name: String
    public let projectIDs: [UUID]
}

public enum PossibleDuplicateDetector {
    public static func detect(projects: [StoredProject]) -> [PossibleDuplicate] {
        Dictionary(grouping: projects, by: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { Set($0.value.map(\.id)).count > 1 }
            .map { PossibleDuplicate(name: $0.key, projectIDs: Set($0.value.map(\.id)).sorted { $0.uuidString < $1.uuidString }) }
            .sorted { $0.name < $1.name }
    }
}
