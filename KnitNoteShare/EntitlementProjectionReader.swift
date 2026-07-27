import Foundation

struct EntitlementProjectionReader {
    private let fileURL: URL?
    private let fileManager: FileManager

    init(
        fileURL: URL?,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func live(
        fileManager: FileManager = .default
    ) -> EntitlementProjectionReader {
        let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier:
                EntitlementProjection.appGroupIdentifier
        )
        return EntitlementProjectionReader(
            fileURL: groupURL?.appendingPathComponent(
                EntitlementProjection.fileName,
                isDirectory: false
            ),
            fileManager: fileManager
        )
    }

    func canAcceptImport(now: Date) -> Bool {
        guard let fileURL else { return false }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return EntitlementProjection.canAcceptImport(nil, now: now)
        }
        guard let data = try? Data(contentsOf: fileURL),
              let projection = try? JSONDecoder().decode(
                  EntitlementProjection.self,
                  from: data
              ) else {
            return false
        }
        return EntitlementProjection.canAcceptImport(projection, now: now)
    }
}
