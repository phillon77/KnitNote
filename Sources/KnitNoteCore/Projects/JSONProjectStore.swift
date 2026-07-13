import Combine
import Foundation

public struct ProjectArchive: Codable, Sendable {
    public let version: Int
    public var projects: [StoredProject]
}

public enum ProjectPhotoChange: Sendable {
    case unchanged
    case replace(Data)
    case remove
}

@MainActor public final class JSONProjectStore: ObservableObject {
    @Published public private(set) var projects: [StoredProject] = []
    private let url: URL
    private let photoService: ProjectPhotoFileService

    public init(url: URL, photoService: ProjectPhotoFileService? = nil) {
        self.url = url
        self.photoService = photoService ?? ProjectPhotoFileService(
            directory: url.deletingLastPathComponent().appendingPathComponent("ProjectPhotos", isDirectory: true)
        )
        load()
    }
    public static func live() -> JSONProjectStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONProjectStore(url: base.appendingPathComponent("KnitNote/projects-v1.json"))
    }
    public func add(name: String) throws { try add(name: name, photoData: nil) }
    public func add(name: String, photoData: Data?) throws {
        var project = try StoredProject(name: name)
        var newFilename: String?
        do {
            if let photoData {
                newFilename = try photoService.save(data: photoData, projectID: project.id)
                project.setPhotoFilename(newFilename)
            }
            projects = try persisted(projects + [project])
        } catch {
            if let newFilename { try? photoService.delete(filename: newFilename) }
            throw error
        }
    }
    public func delete(id: UUID) throws {
        let filename = projects.first(where: { $0.id == id })?.photoFilename
        projects = try persisted(projects.filter { $0.id != id })
        if let filename { try? photoService.delete(filename: filename) }
    }
    public func rename(id: UUID, to name: String) throws { try mutate(id: id) { try $0.rename(to: name) } }
    public func updateProject(id: UUID, name: String, photoChange: ProjectPhotoChange) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let oldFilename = projects[index].photoFilename
        var updated = projects[index]
        try updated.rename(to: name)
        var newFilename: String?
        do {
            switch photoChange {
            case .unchanged:
                break
            case let .replace(data):
                newFilename = try photoService.save(data: data, projectID: id)
                updated.setPhotoFilename(newFilename)
            case .remove:
                updated.setPhotoFilename(nil)
            }
            var staged = projects
            staged[index] = updated
            projects = try persisted(staged)
        } catch {
            if let newFilename { try? photoService.delete(filename: newFilename) }
            throw error
        }
        if let oldFilename, oldFilename != updated.photoFilename {
            try? photoService.delete(filename: oldFilename)
        }
    }
    public func completeRow(id: UUID) throws { try mutate(id: id) { $0.completeRow() } }
    public func undoRow(id: UUID) throws { try mutate(id: id) { $0.undoRow() } }
    public func saveNote(projectID: UUID, row: Int, text: String) throws { try mutate(id: projectID) { try $0.saveNote(row: row, text: text) } }
    public func deleteNote(projectID: UUID, row: Int) throws { try mutate(id: projectID) { $0.deleteNote(row: row) } }
    public func addPattern(projectID: UUID, pattern: PatternDocument) throws { try mutate(id: projectID) { $0.addPattern(pattern) } }
    public func deletePattern(projectID: UUID, id: UUID) throws { try mutate(id: projectID) { $0.deletePattern(id: id) } }
    public func savePatternPageNote(projectID: UUID, patternID: UUID, pageIndex: Int, text: String) throws { try mutate(id: projectID) { $0.savePatternPageNote(patternID: patternID, pageIndex: pageIndex, text: text) } }
    public func updatePatternState(projectID: UUID, id: UUID, pageIndex: Int, highlightPosition: Double) throws { try mutate(id: projectID) { $0.updatePatternState(id: id, pageIndex: pageIndex, highlightPosition: highlightPosition) } }
    public func updatePatternState(projectID: UUID, id: UUID, state: PatternReadingState) throws { try mutate(id: projectID) { $0.updatePatternState(id: id, state: state) } }
    public func project(id: UUID) -> StoredProject? { projects.first { $0.id == id } }
    public func photoURL(for project: StoredProject) -> URL? { project.photoFilename.map(photoService.url(filename:)) }
    private func mutate(id: UUID, _ body: (inout StoredProject) throws -> Void) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var staged = projects
        try body(&staged[index])
        projects = try persisted(staged)
    }
    private func load() {
        guard let data = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(ProjectArchive.self, from: data) else { return }
        projects = archive.projects.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func persisted(_ values: [StoredProject]) throws -> [StoredProject] {
        let sorted = values.sorted { $0.updatedAt > $1.updatedAt }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ProjectArchive(version: 6, projects: sorted))
        try data.write(to: url, options: .atomic)
        return sorted
    }
}
