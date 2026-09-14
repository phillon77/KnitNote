import Foundation
import Observation

struct JournalShareSource: Sendable {
    let projectName: String
    let entry: ProjectJournalEntry
    let photoURL: URL
}

struct JournalSharePayload: Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    let text: String

    init(id: UUID = UUID(), fileURL: URL, text: String) {
        self.id = id
        self.fileURL = fileURL
        self.text = text
    }
}

enum JournalSharePreviewFailure: Error, Equatable, Sendable {
    case photoUnavailable
    case renderingFailed
}

enum JournalSharePreviewState: Equatable, Sendable {
    case loading
    case ready
    case failed(JournalSharePreviewFailure)
    case dismissed
}

enum JournalSharePreviewActionError: Error, Equatable, Sendable {
    case previewUnavailable
    case actionInProgress
}

enum JournalPhotoSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(JournalPhotoSaveError)
    case cancelled
}

@MainActor
@Observable final class JournalSharePreviewModel {
    var format: JournalShareFormat = .post
    var visibility = JournalShareVisibility()
    var editableText: String
    var includesHashtag = true

    private(set) var state: JournalSharePreviewState = .loading
    private(set) var previewJPEG: Data?
    private(set) var previewFormat: JournalShareFormat?
    private(set) var photoSaveError: JournalPhotoSaveError?
    private(set) var isSavingPhoto = false
    private(set) var photoSaveState: JournalPhotoSaveState = .idle

    var canShare: Bool {
        state == .ready && activeShare == nil && previewDescription == currentDescription
    }
    var canCopy: Bool { state != .dismissed }

    private let source: JournalShareSource
    private let locale: Locale
    private let renderer: any JournalShareCardRendering
    private let exportService: any JournalShareExporting
    private let photoSaver: any JournalPhotoSaving
    private let textCopier: any JournalTextCopying
    private var gate = JournalShareGenerationGate()
    private var activeShare: JournalSharePayload?
    private var previewDescription: JournalShareCardDescription?

    init(
        source: JournalShareSource,
        locale: Locale,
        renderer: any JournalShareCardRendering,
        exportService: any JournalShareExporting,
        photoSaver: any JournalPhotoSaving,
        textCopier: any JournalTextCopying
    ) {
        self.source = source
        self.locale = locale
        self.renderer = renderer
        self.exportService = exportService
        self.photoSaver = photoSaver
        self.textCopier = textCopier
        editableText = source.entry.caption ?? ""
        let maintenance = exportService
        Task.detached {
            _ = try? maintenance.removeStaleExports(olderThan: 86_400, maximumRemovals: 50)
        }
    }

    func refreshPreview() async {
        guard state != .dismissed else { return }
        let token = gate.begin()
        state = .loading
        let description = currentDescription
        do {
            let bytes = try await Self.loadSafeRegularFile(at: source.photoURL)
            try Task.checkCancellation()
            let rendered = try await renderer.renderJPEG(description: description, photoData: bytes)
            try Task.checkCancellation()
            guard gate.finish(token), state != .dismissed, description == currentDescription else { return }
            previewJPEG = rendered
            previewFormat = description.format
            previewDescription = description
            state = .ready
        } catch is CancellationError {
            return
        } catch JournalShareRenderError.invalidPhoto {
            guard gate.finish(token), state != .dismissed, description == currentDescription else { return }
            previewJPEG = nil
            previewFormat = nil
            previewDescription = nil
            state = .failed(.photoUnavailable)
        } catch let error as JournalSharePreviewFailure {
            guard gate.finish(token), state != .dismissed, description == currentDescription else { return }
            previewJPEG = nil
            previewFormat = nil
            previewDescription = nil
            state = .failed(error)
        } catch {
            guard gate.finish(token), state != .dismissed, description == currentDescription else { return }
            previewJPEG = nil
            previewFormat = nil
            previewDescription = nil
            state = .failed(.renderingFailed)
        }
    }

    func prepareShare() throws -> JournalSharePayload {
        guard activeShare == nil else { throw JournalSharePreviewActionError.actionInProgress }
        guard canShare, let previewJPEG else { throw JournalSharePreviewActionError.previewUnavailable }
        let url = try exportService.exportJPEG(previewJPEG, entryID: source.entry.id)
        let payload = JournalSharePayload(
            fileURL: url,
            text: JournalShareTextComposer.compose(text: editableText, includeHashtag: includesHashtag)
        )
        activeShare = payload
        return payload
    }

    func saveToPhotos() async {
        guard !isSavingPhoto, canShare, let previewJPEG else { return }
        isSavingPhoto = true
        photoSaveError = nil
        photoSaveState = .saving
        var exportedURL: URL?
        defer {
            if let exportedURL { try? exportService.removeExport(at: exportedURL) }
            isSavingPhoto = false
        }
        do {
            let url = try exportService.exportJPEG(previewJPEG, entryID: source.entry.id)
            exportedURL = url
            let outcome = try await photoSaver.saveJPEG(at: url)
            guard state != .dismissed else { return }
            switch outcome {
            case .saved:
                photoSaveState = .saved
            case .cancelled:
                photoSaveState = .cancelled
            }
        } catch let error as JournalPhotoSaveError {
            guard state != .dismissed else { return }
            photoSaveError = error
            photoSaveState = .failed(error)
        } catch {
            guard state != .dismissed else { return }
            photoSaveError = .writeFailed
            photoSaveState = .failed(.writeFailed)
        }
    }

    @discardableResult
    func copyText() -> Bool {
        guard canCopy else { return false }
        return textCopier.copy(
            JournalShareTextComposer.compose(text: editableText, includeHashtag: includesHashtag)
        )
    }

    func finishSharing(_ payload: JournalSharePayload) {
        guard activeShare?.id == payload.id else { return }
        activeShare = nil
        try? exportService.removeExport(at: payload.fileURL)
    }

    func dismiss() {
        guard state != .dismissed else { return }
        gate.cancel()
        state = .dismissed
        previewJPEG = nil
        previewDescription = nil
        if isSavingPhoto { photoSaveState = .cancelled }
    }

    nonisolated private static func loadSafeRegularFile(at url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let candidate = url.standardizedFileURL
                guard candidate.isFileURL,
                      FileManager.default.fileExists(atPath: candidate.path),
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) == nil else {
                    throw JournalSharePreviewFailure.photoUnavailable
                }
                let parent = candidate.deletingLastPathComponent()
                let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard parentValues.isDirectory == true,
                      parentValues.isSymbolicLink != true,
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path)) == nil else {
                    throw JournalSharePreviewFailure.photoUnavailable
                }
                let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw JournalSharePreviewFailure.photoUnavailable
                }
                let data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
                try Task.checkCancellation()
                guard !data.isEmpty else { throw JournalSharePreviewFailure.photoUnavailable }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw JournalSharePreviewFailure.photoUnavailable
            }
        }.value
    }

    private var currentDescription: JournalShareCardDescription {
        JournalShareCardDescription.make(
            format: format,
            visibility: visibility,
            projectName: source.projectName,
            createdAt: source.entry.createdAt,
            caption: editableText,
            locale: locale
        )
    }
}
