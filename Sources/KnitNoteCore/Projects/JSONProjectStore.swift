import Combine
import Foundation

public struct ProjectArchive: Codable, Sendable {
    public let version: Int
    public var projects: [StoredProject]
}

@MainActor public final class JSONProjectStore: ObservableObject {
    @Published public private(set) var projects: [StoredProject] = []
    private let url: URL

    public init(url: URL) { self.url = url; load() }
    public static func live() -> JSONProjectStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONProjectStore(url: base.appendingPathComponent("KnitNote/projects-v1.json"))
    }
    public func add(name: String) throws { projects.append(try StoredProject(name: name)); try persist() }
    public func delete(id: UUID) throws { projects.removeAll { $0.id == id }; try persist() }
    public func rename(id: UUID, to name: String) throws { try mutate(id: id) { try $0.rename(to: name) } }
    public func completeRow(id: UUID) throws { try mutate(id: id) { $0.completeRow() } }
    public func undoRow(id: UUID) throws { try mutate(id: id) { $0.undoRow() } }
    public func saveNote(projectID: UUID, row: Int, text: String) throws { try mutate(id: projectID) { try $0.saveNote(row: row, text: text) } }
    public func deleteNote(projectID: UUID, row: Int) throws { try mutate(id: projectID) { $0.deleteNote(row: row) } }
    public func addPattern(projectID: UUID, pattern: PatternDocument) throws { try mutate(id: projectID) { $0.addPattern(pattern) } }
    public func deletePattern(projectID: UUID, id: UUID) throws { try mutate(id: projectID) { $0.deletePattern(id: id) } }
    public func updatePatternState(projectID: UUID, id: UUID, pageIndex: Int, highlightPosition: Double) throws { try mutate(id: projectID) { $0.updatePatternState(id: id, pageIndex: pageIndex, highlightPosition: highlightPosition) } }
    public func updatePatternState(projectID: UUID, id: UUID, state: PatternReadingState) throws { try mutate(id: projectID) { $0.updatePatternState(id: id, state: state) } }
    public func project(id: UUID) -> StoredProject? { projects.first { $0.id == id } }
    private func mutate(id: UUID, _ body: (inout StoredProject) throws -> Void) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        try body(&projects[index]); try persist()
    }
    private func load() {
        guard let data = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(ProjectArchive.self, from: data) else { return }
        projects = archive.projects.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func persist() throws {
        projects.sort { $0.updatedAt > $1.updatedAt }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ProjectArchive(version: 5, projects: projects))
        try data.write(to: url, options: .atomic)
    }
}
