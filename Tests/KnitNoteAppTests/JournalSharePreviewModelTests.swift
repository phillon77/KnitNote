import Foundation
import Testing
@testable import KnitNote

@MainActor
@Suite struct JournalSharePreviewModelTests {
    @Test func defaultsAndInitializationMaintenanceDoNotRequestPhotos() async throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()

        #expect(model.format == .post)
        #expect(model.visibility == JournalShareVisibility())
        #expect(model.includesHashtag)
        #expect(model.editableText == "完成衣身 🧶")
        #expect(fixture.photoSaver.calls == 0)
        await fixture.exporter.waitForMaintenance()
        #expect(fixture.exporter.staleCleanupCalls.count == 1)
        #expect(fixture.exporter.staleCleanupCalls.first?.0 == 86_400)
        #expect(fixture.exporter.staleCleanupCalls.first?.1 == 50)
    }

    @Test func editableTextFeedsCardWhileHashtagOnlyFeedsComposedText() async throws {
        let renderer = RendererSpy()
        let fixture = try Fixture(renderer: renderer)
        let model = fixture.makeModel()
        model.editableText = "手動修改全文"
        model.includesHashtag = true

        await model.refreshPreview()
        let payload = try await model.prepareShare()

        #expect(renderer.descriptions.last?.caption == "手動修改全文")
        #expect(renderer.descriptions.last?.caption?.contains("#KnitNote") == false)
        #expect(payload.text == "手動修改全文\n\n#KnitNote")
        #expect(try Data(contentsOf: payload.fileURL) == Fixture.renderedJPEG)
    }

    @Test func staleRenderFailureCannotReplaceCurrentState() async throws {
        let renderer = ControllableRenderer()
        let fixture = try Fixture(renderer: renderer)
        let model = fixture.makeModel()

        let old = Task { await model.refreshPreview() }
        await renderer.waitForCallCount(1)
        model.format = .story
        let current = Task { await model.refreshPreview() }
        await renderer.waitForCallCount(2)
        renderer.finish(call: 1, with: .success(Data([9])))
        await current.value
        renderer.finish(call: 0, with: .failure(TestError.render))
        await old.value

        #expect(model.previewJPEG == Data([9]))
        #expect(model.previewFormat == .story)
        #expect(model.state == .ready)
    }

    @Test func renderSuccessForSettingsChangedWithoutRefreshIsRejected() async throws {
        let renderer = ControllableRenderer()
        let fixture = try Fixture(renderer: renderer)
        let model = fixture.makeModel()

        let rendering = Task { await model.refreshPreview() }
        await renderer.waitForCallCount(1)
        model.visibility.showsCaption = false
        renderer.finish(call: 0, with: .success(Data([7])))
        await rendering.value

        #expect(model.previewJPEG == nil)
        #expect(model.previewFormat == nil)
        #expect(!model.canShare)
    }

    @Test func missingAndUnsafePhotoCanRetryAfterRepair() async throws {
        let fixture = try Fixture(createPhoto: false)
        let model = fixture.makeModel()
        await model.refreshPreview()
        #expect(model.state == .failed(.photoUnavailable))

        try Fixture.sourcePhoto.write(to: fixture.photoURL)
        await model.refreshPreview()
        #expect(model.state == .ready)

        let outside = fixture.root.appendingPathComponent("outside.jpg")
        try Fixture.sourcePhoto.write(to: outside)
        try FileManager.default.removeItem(at: fixture.photoURL)
        try FileManager.default.createSymbolicLink(at: fixture.photoURL, withDestinationURL: outside)
        await model.refreshPreview()
        #expect(model.state == .failed(.photoUnavailable))
    }

    @Test func rendererInvalidPhotoMapsToRetryablePhotoFailure() async throws {
        let fixture = try Fixture(renderer: InvalidPhotoRenderer())
        let model = fixture.makeModel()
        await model.refreshPreview()
        #expect(model.state == .failed(.photoUnavailable))
        #expect(model.previewJPEG == nil)
    }

    @Test func legitimateSystemVarAliasCanLoadARegularPhoto() async throws {
        let fixture = try Fixture()
        let privatePath = fixture.photoURL.resolvingSymlinksInPath().path
        let aliasPath = privatePath.replacingOccurrences(of: "/private/var/", with: "/var/")
        let aliasSource = JournalShareSource(
            projectName: fixture.source.projectName,
            entry: fixture.source.entry,
            photoURL: URL(fileURLWithPath: aliasPath)
        )
        let model = JournalSharePreviewModel(
            source: aliasSource,
            locale: fixture.locale,
            renderer: fixture.renderer,
            exportService: fixture.exporter,
            photoSaver: fixture.photoSaver,
            textCopier: fixture.copier
        )
        await model.refreshPreview()
        #expect(model.state == .ready)
    }

    @Test func photoInsideArbitrarySymlinkedDirectoryIsRejected() async throws {
        let fixture = try Fixture()
        let actualDirectory = fixture.root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: false)
        let actualPhoto = actualDirectory.appendingPathComponent("source.jpg")
        try Fixture.sourcePhoto.write(to: actualPhoto)
        let linkedDirectory = fixture.root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: actualDirectory)
        let unsafeSource = JournalShareSource(
            projectName: fixture.source.projectName,
            entry: fixture.source.entry,
            photoURL: linkedDirectory.appendingPathComponent("source.jpg")
        )
        let model = JournalSharePreviewModel(
            source: unsafeSource,
            locale: fixture.locale,
            renderer: fixture.renderer,
            exportService: fixture.exporter,
            photoSaver: fixture.photoSaver,
            textCopier: fixture.copier
        )

        await model.refreshPreview()
        #expect(model.state == .failed(.photoUnavailable))
    }

    @Test func sourceEntryAndPhotoBytesRemainUnchangedAcrossActions() async throws {
        let fixture = try Fixture()
        let sourceEntryBefore = try JSONEncoder().encode(fixture.source.entry)
        let sourcePhotoBefore = try Data(contentsOf: fixture.photoURL)
        let model = fixture.makeModel()

        await model.refreshPreview()
        let payload = try await model.prepareShare()
        model.copyText()
        model.finishSharing(payload)
        await model.saveToPhotos()

        #expect(try JSONEncoder().encode(fixture.source.entry) == sourceEntryBefore)
        #expect(try Data(contentsOf: fixture.photoURL) == sourcePhotoBefore)
    }

    @Test func deniedAndWriteFailedPhotosHaveDistinctErrorsWithoutDisablingActions() async throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        await model.refreshPreview()

        fixture.photoSaver.result = .failure(JournalPhotoSaveError.denied)
        await model.saveToPhotos()
        #expect(model.photoSaveError == .denied)
        #expect(model.photoSaveState == .failed(.denied))
        #expect(model.canShare && model.canCopy)

        fixture.photoSaver.result = .failure(JournalPhotoSaveError.writeFailed)
        await model.saveToPhotos()
        #expect(model.photoSaveError == .writeFailed)
        #expect(model.photoSaveState == .failed(.writeFailed))
        #expect(model.canShare && model.canCopy)
    }

    @Test func copyUsesExactFullComposedTextAndDuplicateCopyIsAllowed() throws {
        let fixture = try Fixture(caption: "第一行\n第二行 🧶")
        let model = fixture.makeModel()
        model.copyText()
        model.copyText()
        #expect(fixture.copier.values == ["第一行\n第二行 🧶\n\n#KnitNote", "第一行\n第二行 🧶\n\n#KnitNote"])
    }

    @Test func duplicateShareAndSaveActionsAreRejectedWhileActive() async throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        await model.refreshPreview()
        let first = try await model.prepareShare()
        await #expect(throws: JournalSharePreviewActionError.actionInProgress) { try await model.prepareShare() }
        model.finishSharing(first)

        fixture.photoSaver.suspend = true
        let saving = Task { await model.saveToPhotos() }
        await fixture.photoSaver.waitUntilCalled()
        await model.saveToPhotos()
        #expect(fixture.photoSaver.calls == 1)
        fixture.photoSaver.resume()
        await saving.value
    }

    @Test func settingsChangePreventsSavingStalePreview() async throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        await model.refreshPreview()
        model.format = .story

        await model.saveToPhotos()
        #expect(fixture.photoSaver.calls == 0)
        #expect(model.photoSaveState == .idle)
    }

    @Test func successfulPhotoSavePublishesTypedOutcomeAndCleansExport() async throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        await model.refreshPreview()
        await model.saveToPhotos()

        let savedURL = try #require(fixture.photoSaver.urls.first)
        #expect(model.photoSaveState == .saved)
        #expect(!FileManager.default.fileExists(atPath: savedURL.path))
    }

    @Test func dismissalDefersActiveShareCleanupAndRejectsStaleAnnouncements() async throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        await model.refreshPreview()
        let payload = try await model.prepareShare()

        model.dismiss()
        #expect(FileManager.default.fileExists(atPath: payload.fileURL.path))
        #expect(model.state == .dismissed)
        model.finishSharing(payload)
        #expect(!FileManager.default.fileExists(atPath: payload.fileURL.path))
        #expect(model.state == .dismissed)
    }

    @Test func dismissalDoesNotUnlinkFileWhilePhotosIsReadingIt() async throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        await model.refreshPreview()
        fixture.photoSaver.suspend = true
        fixture.photoSaver.result = .failure(JournalPhotoSaveError.writeFailed)

        let saving = Task { await model.saveToPhotos() }
        await fixture.photoSaver.waitUntilCalled()
        let readingURL = try #require(fixture.photoSaver.urls.first)
        model.dismiss()
        #expect(FileManager.default.fileExists(atPath: readingURL.path))
        fixture.photoSaver.resume()
        await saving.value

        #expect(!FileManager.default.fileExists(atPath: readingURL.path))
        #expect(model.photoSaveError == nil)
        #expect(model.photoSaveState == .cancelled)
        #expect(model.state == .dismissed)
    }

    @Test func finishSharingRemovesRealExportsBeforeAndAfterDismissal() async throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        await model.refreshPreview()
        let payload = try await model.prepareShare()
        #expect(FileManager.default.fileExists(atPath: payload.fileURL.path))
        model.finishSharing(payload)
        #expect(!FileManager.default.fileExists(atPath: payload.fileURL.path))

        let second = try await model.prepareShare()
        model.finishSharing(second)
        model.dismiss()
        #expect(!FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    @Test func injectedLocaleBuildsLocalizedCardDate() async throws {
        let renderer = RendererSpy()
        let fixture = try Fixture(locale: Locale(identifier: "fr_FR"), renderer: renderer)
        let model = fixture.makeModel()
        await model.refreshPreview()
        #expect(renderer.descriptions.last?.formattedDate == "1 janv. 1970")
    }
}

@MainActor
private final class RendererSpy: JournalShareCardRendering {
    var descriptions: [JournalShareCardDescription] = []
    func renderJPEG(description: JournalShareCardDescription, photoData: Data) async throws -> Data {
        descriptions.append(description)
        return Fixture.renderedJPEG
    }
}

@MainActor private struct InvalidPhotoRenderer: JournalShareCardRendering {
    func renderJPEG(description: JournalShareCardDescription, photoData: Data) async throws -> Data {
        throw JournalShareRenderError.invalidPhoto
    }
}

@MainActor
private final class ControllableRenderer: JournalShareCardRendering {
    private var continuations: [CheckedContinuation<Data, Error>?] = []
    func renderJPEG(description: JournalShareCardDescription, photoData: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func waitForCallCount(_ count: Int) async {
        while continuations.count < count { await Task.yield() }
    }
    func finish(call: Int, with result: Result<Data, Error>) {
        let continuation = continuations[call]
        continuations[call] = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class PhotoSaverSpy: JournalPhotoSaving {
    var calls = 0
    var urls: [URL] = []
    var result: Result<Void, Error> = .success(())
    var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    func saveJPEG(at url: URL) async throws {
        calls += 1
        urls.append(url)
        if suspend { await withCheckedContinuation { continuation = $0 } }
        try result.get()
    }
    func waitUntilCalled() async { while calls == 0 { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor private final class CopierSpy: JournalTextCopying {
    var values: [String] = []
    func copy(_ text: String) { values.append(text) }
}

private enum TestError: Error { case render }

private final class ExportServiceSpy: JournalShareExporting, @unchecked Sendable {
    let service: JournalShareTemporaryExportService
    private let lock = NSLock()
    private(set) var staleCleanupCalls: [(TimeInterval, Int)] = []
    init(service: JournalShareTemporaryExportService) { self.service = service }
    func exportJPEG(_ data: Data, entryID: UUID) throws -> URL { try service.exportJPEG(data, entryID: entryID) }
    func removeExport(at url: URL) throws { try service.removeExport(at: url) }
    func removeStaleExports(olderThan age: TimeInterval, maximumRemovals: Int) throws -> Int {
        lock.withLock { staleCleanupCalls.append((age, maximumRemovals)) }
        return try service.removeStaleExports(olderThan: age, maximumRemovals: maximumRemovals)
    }
    func waitForMaintenance() async {
        while lock.withLock({ staleCleanupCalls.isEmpty }) { await Task.yield() }
    }
}

@MainActor
private final class Fixture {
    static let sourcePhoto = Data("actual source photo bytes".utf8)
    static let renderedJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let root: URL
    let photoURL: URL
    let source: JournalShareSource
    let renderer: any JournalShareCardRendering
    let exporter: ExportServiceSpy
    let photoSaver = PhotoSaverSpy()
    let copier = CopierSpy()
    let locale: Locale

    init(caption: String = "完成衣身 🧶", locale: Locale = Locale(identifier: "en_US"), createPhoto: Bool = true, renderer: (any JournalShareCardRendering)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        photoURL = root.appendingPathComponent("source.jpg")
        if createPhoto { try Self.sourcePhoto.write(to: photoURL) }
        let id = UUID()
        let projectID = UUID()
        let token = UUID()
        let stem = "\(projectID.uuidString)-\(id.uuidString)-\(token.uuidString)"
        let entry = try ProjectJournalEntry(id: id, photoFilename: "\(stem)-full.jpg", thumbnailFilename: "\(stem)-thumb.jpg", caption: caption, createdAt: Date(timeIntervalSince1970: 0))
        source = JournalShareSource(projectName: "紅茶開衫", entry: entry, photoURL: photoURL)
        self.renderer = renderer ?? RendererSpy()
        exporter = ExportServiceSpy(service: JournalShareTemporaryExportService(root: root.appendingPathComponent("exports")))
        self.locale = locale
    }

    func makeModel() -> JournalSharePreviewModel {
        JournalSharePreviewModel(source: source, locale: locale, renderer: renderer, exportService: exporter, photoSaver: photoSaver, textCopier: copier)
    }
}
