import Foundation
import Testing

@Suite("Journal share presentation contracts")
struct JournalSharePresentationContractTests {
    @Test func previewRefreshesOnlyForCardAffectingEquatableSettings() throws {
        let source = try projectSource(named: "JournalSharing/JournalSharePreviewView")

        #expect(source.contains(".task(id: previewSettings)"))
        #expect(source.contains("model.format"))
        #expect(source.contains("model.visibility"))
        #expect(source.contains("model.editableText"))
        #expect(!source.contains("PreviewSettings(format: model.format, visibility: model.visibility, editableText: model.editableText, includesHashtag:"))
    }

    @Test func outputAndCleanupContractsRemainExplicit() throws {
        let preview = try projectSource(named: "JournalSharing/JournalSharePreviewView")
        let activity = try projectSource(named: "JournalSharing/JournalActivityView")

        #expect(preview.contains("model.canShare && !model.isSavingPhoto"))
        #expect(preview.contains("model.canCopy"))
        #expect(preview.contains("model.photoSaveState"))
        #expect(preview.contains("activityPayload = nil"))
        #expect(preview.contains("model.finishSharing(payload)"))
        #expect(preview.contains("onDismiss:"))
        #expect(activity.contains("UIActivityViewController"))
        #expect(activity.contains("completionWithItemsHandler"))
    }

    @Test func previewHasStableIdentifiersAndAccessibleCombinedImage() throws {
        let source = try projectSource(named: "JournalSharing/JournalSharePreviewView")
        for identifier in [
            "journalShare.preview", "journalShare.format", "journalShare.showProject",
            "journalShare.showDate", "journalShare.showCaption", "journalShare.showBrand",
            "journalShare.text", "journalShare.hashtag", "journalShare.share",
            "journalShare.save", "journalShare.copy"
        ] {
            #expect(source.contains(identifier))
        }
        #expect(source.contains(".accessibilityElement(children: .ignore)"))
        #expect(source.contains("if dynamicTypeSize.isAccessibilitySize"))
        #expect(source.contains("case .failed(.photoUnavailable)"))
        #expect(source.contains("case .failed(.renderingFailed)"))
        #expect(source.contains(".frame(minHeight: 44)"))
        #expect(source.contains("UIAccessibility.post(notification: .announcement"))
        #expect(source.contains("UIApplication.openSettingsURLString"))
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func projectSource(named name: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: "KnitNote/Projects/\(name).swift"), encoding: .utf8)
    }
}
