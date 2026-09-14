import Foundation

enum JournalPhotoSaveError: Error, Equatable, Sendable {
    case denied
    case writeFailed
}

enum JournalImageSaveOutcome: Equatable, Sendable {
    case saved
    case cancelled
}

@MainActor
protocol JournalPhotoSaving {
    func saveJPEG(at url: URL) async throws -> JournalImageSaveOutcome
}

@MainActor
protocol JournalTextCopying {
    @discardableResult
    func copy(_ text: String) -> Bool
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
    func saveJPEG(at url: URL) async throws -> JournalImageSaveOutcome {
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
        return .saved
    }
}

struct IOSJournalTextCopier: JournalTextCopying {
    func copy(_ text: String) -> Bool {
        UIPasteboard.general.string = text
        return true
    }
}
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
struct MacJournalImageSaver: JournalPhotoSaving {
    typealias DestinationChooser = @MainActor (_ suggestedFilename: String) -> URL?

    private let destinationChooser: DestinationChooser

    init(_ destinationChooser: @escaping DestinationChooser = Self.chooseDestination) {
        self.destinationChooser = destinationChooser
    }

    func saveJPEG(at url: URL) async throws -> JournalImageSaveOutcome {
        guard let destination = destinationChooser(url.lastPathComponent) else {
            return .cancelled
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            try data.write(to: destination, options: [.atomic])
            return .saved
        } catch {
            throw JournalPhotoSaveError.writeFailed
        }
    }

    private static func chooseDestination(suggestedFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct MacJournalTextCopier: JournalTextCopying {
    func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

enum MacJournalSharingItems {
    static func items(for payload: JournalSharePayload) -> [Any] {
        [payload.fileURL, payload.text]
    }
}
#endif
