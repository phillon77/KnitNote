import Foundation

enum JournalPhotoSaveError: Error, Equatable, Sendable {
    case denied
    case writeFailed
}

@MainActor
protocol JournalPhotoSaving {
    func saveJPEG(at url: URL) async throws
}

@MainActor
protocol JournalTextCopying {
    func copy(_ text: String)
}

protocol JournalShareExporting: Sendable {
    func exportJPEG(_ data: Data, entryID: UUID) throws -> URL
    func removeExport(at url: URL) throws
    @discardableResult
    func removeStaleExports(olderThan age: TimeInterval, maximumRemovals: Int) throws -> Int
}

extension JournalShareTemporaryExportService: JournalShareExporting {
    func removeStaleExports(olderThan age: TimeInterval, maximumRemovals: Int) throws -> Int {
        try removeStaleExports(olderThan: age, now: .now, maximumRemovals: maximumRemovals)
    }
}

#if os(iOS)
import Photos
import UIKit

struct IOSJournalPhotoSaver: JournalPhotoSaving {
    func saveJPEG(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw JournalPhotoSaveError.denied
        }
        do {
            // Photos invokes this block on its own queue, not the caller's MainActor.
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        } catch {
            throw JournalPhotoSaveError.writeFailed
        }
    }
}

struct IOSJournalTextCopier: JournalTextCopying {
    func copy(_ text: String) { UIPasteboard.general.string = text }
}
#endif
