import Foundation

public struct KnitNoteBackupExportPackage: Sendable {
    public let packageURL: URL
    public let preferredFilename: String

    public init(packageURL: URL, preferredFilename: String) throws {
        let trimmedFilename = preferredFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilename.isEmpty,
              URL(fileURLWithPath: trimmedFilename).lastPathComponent == trimmedFilename else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        self.packageURL = packageURL
        self.preferredFilename = trimmedFilename
    }

    public func fileWrapper() throws -> FileWrapper {
        let wrapper = try Self.makeFileWrapper(at: packageURL)
        guard wrapper.isDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        wrapper.preferredFilename = preferredFilename
        return wrapper
    }

    private static func makeFileWrapper(at url: URL) throws -> FileWrapper {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        if values.isDirectory == true {
            let childURLs = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
            var children: [String: FileWrapper] = [:]
            for childURL in childURLs {
                children[childURL.lastPathComponent] = try makeFileWrapper(at: childURL)
            }
            return FileWrapper(directoryWithFileWrappers: children)
        }

        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return FileWrapper(
            regularFileWithContents: try Data(contentsOf: url, options: .mappedIfSafe)
        )
    }
}
