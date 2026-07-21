import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let knitNoteBackup = UTType(exportedAs: "com.phillon.KnitNote.backup", conformingTo: .package)
}

struct KnitNoteBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.knitNoteBackup]

    private let exportPackage: KnitNoteBackupExportPackage

    init(packageURL: URL, preferredFilename: String) throws {
        exportPackage = try KnitNoteBackupExportPackage(
            packageURL: packageURL,
            preferredFilename: preferredFilename
        )
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try exportPackage.fileWrapper()
    }
}
