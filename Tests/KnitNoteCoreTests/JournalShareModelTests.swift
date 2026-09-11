import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct JournalShareModelTests {
    @Test func formatsExposeExactPixelSizes() {
        #expect(JournalShareFormat.post.pixelWidth == 1_080)
        #expect(JournalShareFormat.post.pixelHeight == 1_350)
        #expect(JournalShareFormat.story.pixelWidth == 1_080)
        #expect(JournalShareFormat.story.pixelHeight == 1_920)
    }

    @Test func descriptionOmitsHiddenMetadataWithoutChangingSource() {
        let visibility = JournalShareVisibility(
            showsProjectName: false,
            showsDate: true,
            showsCaption: false,
            showsBrand: false
        )
        let sourceCaption = "  第 36 行 🧶  "
        let result = JournalShareCardDescription.make(
            format: .post,
            visibility: visibility,
            projectName: "紅茶開衫",
            createdAt: Date(timeIntervalSince1970: 0),
            caption: sourceCaption,
            locale: Locale(identifier: "zh-Hant")
        )
        #expect(result.projectName == nil)
        #expect(result.caption == nil)
        #expect(result.formattedDate != nil)

        let visibleResult = JournalShareCardDescription.make(
            format: .post,
            visibility: JournalShareVisibility(),
            projectName: "紅茶開衫",
            createdAt: Date(timeIntervalSince1970: 0),
            caption: sourceCaption,
            locale: Locale(identifier: "zh-Hant")
        )
        #expect(visibleResult.caption == sourceCaption)
    }

    @Test(arguments: ["", "完成衣身", "完成衣身\n\n#knitnote", "#KnitNote 原本就在這裡"])
    func hashtagCompositionIsIdempotent(_ text: String) {
        let once = JournalShareTextComposer.compose(text: text, includeHashtag: true)
        let twice = JournalShareTextComposer.compose(text: once, includeHashtag: true)
        #expect(once == twice)
        #expect(once.localizedCaseInsensitiveContains("#knitnote"))
    }

    @Test func disablingHashtagPreservesTextVerbatim() {
        let text = "  完成衣身 🧶  \n\n#KnitNote 原本就在這裡  "
        #expect(JournalShareTextComposer.compose(text: text, includeHashtag: false) == text)
    }

    @Test func defaultVisibilityShowsEveryField() {
        let visibility = JournalShareVisibility()
        #expect(visibility.showsProjectName)
        #expect(visibility.showsDate)
        #expect(visibility.showsCaption)
        #expect(visibility.showsBrand)
    }

    @Test func generationGateRejectsStaleCompletion() {
        var gate = JournalShareGenerationGate()
        let old = gate.begin()
        let current = gate.begin()
        #expect(!gate.finish(old))
        #expect(gate.finish(current))
    }

    @Test func cancellingGenerationRejectsPriorToken() {
        var gate = JournalShareGenerationGate()
        let token = gate.begin()
        gate.cancel()
        #expect(!gate.finish(token))
    }
}
