import Foundation
import Testing

@Suite struct YarnLabelPhotoViewContractTests {
    @Test func detailShowsOnlyPopulatedStructuredFieldsAndLabelGallery() throws {
        let detail = try source("KnitNote/Yarn/YarnDetailView.swift")

        #expect(detail.contains("if let ballWeightGrams = yarn.ballWeightGrams"))
        #expect(detail.contains("if let lengthMeters = yarn.lengthMeters"))
        #expect(detail.contains("if let fiberContent = yarn.fiberContent"))
        #expect(detail.contains("if let recommendedNeedleMM = yarn.recommendedNeedleMM"))
        #expect(detail.contains("if let recommendedHookMM = yarn.recommendedHookMM"))
        #expect(detail.contains("YarnLabelPhotoGallery"))
        #expect(detail.contains("store.labelPhotoURLs(for: yarn)"))
    }

    @Test func galleryIsHorizontalAndVoiceOverLabeled() throws {
        let gallery = try source("KnitNote/Yarn/YarnLabelPhotoGallery.swift")

        #expect(gallery.contains("ScrollView(.horizontal"))
        #expect(gallery.contains("Array(items.prefix(2))"))
        #expect(gallery.contains(".accessibilityLabel"))
        #expect(gallery.contains("yarn.labelPhoto.accessibility"))
    }

    @Test func editCanReplaceOrRemoveExistingLabelPhotosAtomically() throws {
        let edit = try source("KnitNote/Yarn/EditYarnView.swift")
        let gallery = try source("KnitNote/Yarn/YarnLabelPhotoGallery.swift")
        let store = try source("Sources/KnitNoteCore/Projects/JSONProjectStore.swift")

        #expect(edit.contains("retainedLabelPhotoFilenames"))
        #expect(edit.contains("YarnLabelPhotoGallery"))
        #expect(edit.contains(".retainExisting(retainedLabelPhotoFilenames)"))
        #expect(gallery.contains("yarn.labelPhoto.remove"))
        #expect(store.contains("case retainExisting([String])"))
        #expect(store.contains("labelPhotoChange"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }
}
