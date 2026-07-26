import Foundation

public enum PatternMarkupFileError: Error, Equatable, Sendable {
    case unsafePath
}

public struct PatternMarkupFileService: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func live() throws -> PatternMarkupFileService { .init(root: try PatternFileService.live().root) }

    public func load(usageID: UUID, pageIndex: Int) throws -> PatternMarkupDocument {
        let file = try usagePageURL(usageID: usageID, pageIndex: pageIndex)
        guard FileManager.default.fileExists(atPath: file.path) else { return PatternMarkupDocument() }
        return try JSONDecoder().decode(PatternMarkupDocument.self, from: Data(contentsOf: file))
    }

    public func save(_ document: PatternMarkupDocument, usageID: UUID, pageIndex: Int) throws {
        let file = try usagePageURL(usageID: usageID, pageIndex: pageIndex)
        if document.strokes.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    public func deleteUsageMarkup(usageID: UUID) throws {
        let directory = try usageMarkupDirectory(usageID: usageID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    public func load(projectID: UUID, patternID: UUID, pageIndex: Int) throws -> PatternMarkupDocument {
        let file = try legacyPageURL(projectID: projectID, patternID: patternID, pageIndex: pageIndex)
        guard FileManager.default.fileExists(atPath: file.path) else { return PatternMarkupDocument() }
        return try JSONDecoder().decode(PatternMarkupDocument.self, from: Data(contentsOf: file))
    }

    public func save(_ document: PatternMarkupDocument, projectID: UUID, patternID: UUID, pageIndex: Int) throws {
        let file = try legacyPageURL(projectID: projectID, patternID: patternID, pageIndex: pageIndex)
        if document.strokes.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    // The pre-library file layout remains readable only while migration and
    // compatibility callers exist. New reads and writes are always usage-owned.
    func deleteLegacyMarkup(projectID: UUID, patternID: UUID) throws {
        let directory = try legacyPatternDirectory(projectID: projectID, patternID: patternID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func copyLegacyMarkup(
        from source: PatternMarkupFileService,
        projectID: UUID,
        patternID: UUID,
        usageID: UUID
    ) throws {
        let sourceDirectory = try source.legacyPatternDirectory(projectID: projectID, patternID: patternID)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else { return }
        let destinationDirectory = try usageMarkupDirectory(usageID: usageID)
        try FileManager.default.createDirectory(
            at: destinationDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceDirectory, to: destinationDirectory)
    }

    func usageMarkupDirectory(usageID: UUID) throws -> URL {
        let markupRoot = try safeDirectory(named: "UsageMarkup", under: validatedRoot())
        return try safeDirectory(named: usageID.uuidString, under: markupRoot)
    }

    private func legacyPatternDirectory(projectID: UUID, patternID: UUID) throws -> URL {
        let projectDirectory = try safeDirectory(named: projectID.uuidString, under: validatedRoot())
        let markupDirectory = try safeDirectory(named: "Markup", under: projectDirectory)
        return try safeDirectory(named: patternID.uuidString, under: markupDirectory)
    }

    private func usagePageURL(usageID: UUID, pageIndex: Int) throws -> URL {
        try safePageURL(pageIndex: pageIndex, under: usageMarkupDirectory(usageID: usageID))
    }

    private func legacyPageURL(projectID: UUID, patternID: UUID, pageIndex: Int) throws -> URL {
        try safePageURL(
            pageIndex: pageIndex,
            under: legacyPatternDirectory(projectID: projectID, patternID: patternID)
        )
    }

    private func validatedRoot() throws -> URL {
        let root = root.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else {
            throw PatternMarkupFileError.unsafePath
        }
        if FileManager.default.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PatternMarkupFileError.unsafePath
            }
        }
        return root
    }

    private func safeDirectory(named name: String, under parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent().path == parent.path,
              directory.resolvingSymlinksInPath().path == directory.path else {
            throw PatternMarkupFileError.unsafePath
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PatternMarkupFileError.unsafePath
            }
        }
        return directory
    }

    private func safePageURL(pageIndex: Int, under directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("\(max(0, pageIndex)).json").standardizedFileURL
        guard file.deletingLastPathComponent().path == directory.path,
              file.resolvingSymlinksInPath().path == file.path else {
            throw PatternMarkupFileError.unsafePath
        }
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PatternMarkupFileError.unsafePath
            }
        }
        return file
    }
}
