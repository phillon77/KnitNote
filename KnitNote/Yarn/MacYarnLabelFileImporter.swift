#if os(macOS)
import Foundation
import UniformTypeIdentifiers

enum MacYarnLabelFileImportError: Error {
    case unsupportedFile
    case tooManyFiles
    case unavailable
}

struct MacYarnLabelFileImporter {
    func load(_ urls: [URL]) throws -> [Data] {
        guard urls.count <= 2 else { throw MacYarnLabelFileImportError.tooManyFiles }
        return try urls.map { url in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .ubiquitousItemDownloadingStatusKey,
                .contentTypeKey,
            ])
            let supportedTypes: [UTType] = [.jpeg, .png, .heic]
            guard values?.isRegularFile != false,
                  let contentType = values?.contentType,
                  supportedTypes.contains(where: { contentType.conforms(to: $0) }) else {
                throw MacYarnLabelFileImportError.unsupportedFile
            }
            if let status = values?.ubiquitousItemDownloadingStatus,
               status == .notDownloaded {
                throw MacYarnLabelFileImportError.unavailable
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else { throw MacYarnLabelFileImportError.unsupportedFile }
            return data
        }
    }
}
#endif
