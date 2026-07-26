import Foundation

public struct PatternInboxFileService: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func enqueue(
        source: URL,
        origin: PatternImportOrigin,
        targetProjectID: UUID?,
        now: Date
    ) throws -> PatternInboxItem {
        let id = UUID()
        let manager = FileManager.default
        let candidates = root.appendingPathComponent(".Candidates", isDirectory: true)
        let itemsRoot = root.appendingPathComponent("Items", isDirectory: true)
        try manager.createDirectory(at: candidates, withIntermediateDirectories: true)
        try manager.createDirectory(at: itemsRoot, withIntermediateDirectories: true)
        let candidate = candidates.appendingPathComponent(id.uuidString)
        do {
            try manager.copyItem(at: source, to: candidate)
            let metadata = try PatternFileService(root: root).inspect(
                candidate,
                fileExtension: source.pathExtension
            )
            let item = PatternInboxItem(
                id: id,
                originalFilename: source.lastPathComponent,
                receivedAt: now,
                origin: origin,
                targetProjectID: targetProjectID,
                stagedFilename: "\(id.uuidString).\(metadata.fileExtension)"
            )
            let staged = stagedURL(for: item)
            try manager.moveItem(at: candidate, to: staged)
            do {
                try JSONEncoder().encode(item).write(to: sidecarURL(for: id), options: .atomic)
            } catch {
                try? manager.removeItem(at: staged)
                throw error
            }
            return item
        } catch {
            try? manager.removeItem(at: candidate)
            throw error
        }
    }

    public func item(id: UUID) -> PatternInboxItem? {
        guard let data = try? Data(contentsOf: sidecarURL(for: id)),
              let item = try? JSONDecoder().decode(PatternInboxItem.self, from: data),
              item.id == id,
              isSafe(item),
              FileManager.default.fileExists(atPath: stagedURL(for: item).path) else {
            return nil
        }
        return item
    }

    public func items() -> [PatternInboxItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Items", isDirectory: true),
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            return item(id: id)
        }.sorted { $0.receivedAt < $1.receivedAt }
    }

    public func stagedURL(for item: PatternInboxItem) -> URL {
        root.appendingPathComponent("Items", isDirectory: true).appendingPathComponent(item.stagedFilename)
    }

    public func remove(_ item: PatternInboxItem) throws {
        guard isSafe(item) else { throw PatternInboxError.invalidItem }
        let manager = FileManager.default
        let sidecar = sidecarURL(for: item.id)
        let staged = stagedURL(for: item)
        if manager.fileExists(atPath: sidecar.path) { try manager.removeItem(at: sidecar) }
        if manager.fileExists(atPath: staged.path) { try manager.removeItem(at: staged) }
    }

    private func sidecarURL(for id: UUID) -> URL {
        root.appendingPathComponent("Items", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    private func isSafe(_ item: PatternInboxItem) -> Bool {
        item.stagedFilename == "\(item.id.uuidString).\(URL(fileURLWithPath: item.originalFilename).pathExtension.lowercased())"
            && !item.originalFilename.isEmpty
    }
}
