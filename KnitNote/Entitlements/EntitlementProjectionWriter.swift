import Foundation

enum EntitlementProjectionWriterError: Error {
    case appGroupUnavailable
}

struct EntitlementProjectionWriter {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func live(
        fileManager: FileManager = .default
    ) throws -> EntitlementProjectionWriter {
        #if os(iOS)
        guard let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier:
                EntitlementProjection.appGroupIdentifier
        ) else {
            throw EntitlementProjectionWriterError.appGroupUnavailable
        }
        return EntitlementProjectionWriter(
            fileURL: groupURL.appendingPathComponent(
                EntitlementProjection.fileName,
                isDirectory: false
            )
        )
        #else
        throw EntitlementProjectionWriterError.appGroupUnavailable
        #endif
    }

    func write(
        snapshot: EntitlementSnapshot,
        generatedAt: Date
    ) throws {
        let projection = EntitlementProjection(
            snapshot: snapshot,
            generatedAt: generatedAt
        )
        let data = try JSONEncoder().encode(projection)
        try data.write(to: fileURL, options: .atomic)
    }
}
