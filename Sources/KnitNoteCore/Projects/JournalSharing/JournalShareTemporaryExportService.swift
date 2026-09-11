import Foundation

public enum JournalShareTemporaryExportError: Error, Equatable, Sendable {
    case unsafeURL
}

public struct JournalShareTemporaryExportService: @unchecked Sendable {
    private let requestedRoot: URL
    private let anchoredPhysicalParent: URL
    private let anchoredPhysicalRoot: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        requestedRoot = root.standardizedFileURL
        anchoredPhysicalParent = requestedRoot.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        anchoredPhysicalRoot = anchoredPhysicalParent
            .appendingPathComponent(requestedRoot.lastPathComponent, isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
    }

    public func exportJPEG(_ data: Data, entryID: UUID) throws -> URL {
        let root = try validatedRoot(createIfNeeded: true)
        let filename = "\(entryID.uuidString)-\(UUID().uuidString).jpg"
        let destination = root.appendingPathComponent(filename, isDirectory: false)
        guard try isSafeOwnedCandidate(destination, under: root, mayNotExist: true) else {
            throw JournalShareTemporaryExportError.unsafeURL
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func removeExport(at url: URL) throws {
        let root = try validatedRoot(createIfNeeded: false)
        let candidate = url.standardizedFileURL
        guard try isSafeOwnedCandidate(candidate, under: root, mayNotExist: true) else {
            throw JournalShareTemporaryExportError.unsafeURL
        }
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw JournalShareTemporaryExportError.unsafeURL
        }
        try fileManager.removeItem(at: candidate)
    }

    @discardableResult
    public func removeStaleExports(
        olderThan age: TimeInterval,
        now: Date = .now,
        maximumRemovals: Int = 50
    ) throws -> Int {
        guard maximumRemovals > 0 else { return 0 }
        let root = try validatedRoot(createIfNeeded: false)
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let cutoff = now.addingTimeInterval(-age)
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        )
        var removed = 0
        for child in children where removed < maximumRemovals {
            guard try isSafeOwnedCandidate(child, under: root, mayNotExist: false) else { continue }
            let values = try child.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else { continue }
            try fileManager.removeItem(at: child)
            removed += 1
        }
        return removed
    }

    private func validatedRoot(createIfNeeded: Bool) throws -> URL {
        if fileManager.fileExists(atPath: requestedRoot.path) {
            let values = try requestedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw JournalShareTemporaryExportError.unsafeURL
            }
        } else if (try? fileManager.destinationOfSymbolicLink(atPath: requestedRoot.path)) != nil {
            throw JournalShareTemporaryExportError.unsafeURL
        }

        let requestedParent = requestedRoot.deletingLastPathComponent()
        let physicalParent = requestedParent.resolvingSymlinksInPath().standardizedFileURL
        guard physicalParent == anchoredPhysicalParent else {
            throw JournalShareTemporaryExportError.unsafeURL
        }
        let parentValues = try physicalParent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw JournalShareTemporaryExportError.unsafeURL
        }
        let physicalRoot = anchoredPhysicalRoot
        guard physicalRoot.deletingLastPathComponent() == physicalParent else {
            throw JournalShareTemporaryExportError.unsafeURL
        }

        if !fileManager.fileExists(atPath: physicalRoot.path) {
            guard createIfNeeded else { return physicalRoot }
            try fileManager.createDirectory(at: physicalRoot, withIntermediateDirectories: false)
        }
        let rootValues = try physicalRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              physicalRoot.resolvingSymlinksInPath() == physicalRoot else {
            throw JournalShareTemporaryExportError.unsafeURL
        }
        return physicalRoot
    }

    private func isSafeOwnedCandidate(_ url: URL, under root: URL, mayNotExist: Bool) throws -> Bool {
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == root,
              isOwnedFilename(candidate.lastPathComponent) else { return false }
        if fileManager.fileExists(atPath: candidate.path) || !mayNotExist {
            guard candidate.resolvingSymlinksInPath() == candidate else { return false }
        } else if (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            return false
        }
        return true
    }

    private func isOwnedFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".jpg") else { return false }
        let stem = String(filename.dropLast(4))
        guard stem.count == 73 else { return false }
        let separator = stem.index(stem.startIndex, offsetBy: 36)
        guard stem[separator] == "-" else { return false }
        let entryPart = String(stem[..<separator])
        let nonceStart = stem.index(after: separator)
        let noncePart = String(stem[nonceStart...])
        return UUID(uuidString: entryPart) != nil && UUID(uuidString: noncePart) != nil
    }
}
