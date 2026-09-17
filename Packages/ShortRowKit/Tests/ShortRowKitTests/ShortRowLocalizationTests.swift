import Foundation
import Testing
@testable import ShortRowKit

struct ShortRowLocalizationTests {
    @Test func regionalChineseUsesTraditionalResourcesAndUnsupportedLocaleFallsBack() {
        let traditional = Locale(identifier: "zh-Hant")
        let english = Locale(identifier: "en")
        for identifier in ["zh_TW", "zh_HK", "zh_MO"] {
            #expect(ShortRowStrings.text("title", locale: Locale(identifier: identifier)) ==
                    ShortRowStrings.text("title", locale: traditional))
        }
        #expect(ShortRowStrings.text("title", locale: traditional) !=
                ShortRowStrings.text("title", locale: english))
        #expect(ShortRowStrings.text("title", locale: Locale(identifier: "de")) ==
                ShortRowStrings.text("title", locale: english))
    }

    @Test func everyInstructionFormatsCountsWithoutLeakingPlaceholders() {
        // Swapped/missing count placeholders would tell the knitter to work the wrong row/width.
        for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hant")] {
            for key in ["out.knit", "out.purl"] {
                let text = ShortRowStrings.format(key, locale: locale, 3, 12, 13)
                #expect(text.contains("3") && text.contains("12") && text.contains("13"))
                #expect(!text.contains("%") && text != key)
            }
            for key in ["back.knit", "back.purl", "finish.knit", "finish.purl"] {
                let text = ShortRowStrings.format(key, locale: locale, 7, 24)
                #expect(text.contains("7") && text.contains("24"))
                #expect(!text.contains("%") && text != key)
            }
            let height = ShortRowStrings.format("actual", locale: locale, "2.4")
            #expect(height.contains("2.4") && !height.contains("%@"))
        }
    }
}
