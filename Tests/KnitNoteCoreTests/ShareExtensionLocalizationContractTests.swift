import Foundation
import Testing

@Suite struct ShareExtensionLocalizationContractTests {
    @Test func shareExtensionHasExactEnglishAndTraditionalChineseCopy() throws {
        let url = patternLibraryRepositoryURL("KnitNoteShare/Localizable.xcstrings")
        let exists = FileManager.default.fileExists(atPath: url.path)

        #expect(exists)
        guard exists else { return }

        let catalog = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expected: [String: [String: String]] = [
            "share.title": ["en": "Add to KnitNote", "zh-Hant": "加入 KnitNote"],
            "share.loading": ["en": "Saving your pattern…", "zh-Hant": "正在儲存織圖…"],
            "share.success": ["en": "Added to KnitNote", "zh-Hant": "已加入 KnitNote"],
            "share.cancel": ["en": "Cancel", "zh-Hant": "取消"],
            "share.close": ["en": "Close", "zh-Hant": "關閉"],
            "share.error.unsupported": ["en": "Share one PDF or supported image file.", "zh-Hant": "請分享一個 PDF 或支援的圖片檔案。"],
            "share.error.multiple": ["en": "Share one pattern file at a time.", "zh-Hant": "一次只能分享一個織圖檔案。"],
            "share.error.access": ["en": "KnitNote could not access this file.", "zh-Hant": "KnitNote 無法存取這個檔案。"],
            "share.error.load": ["en": "The shared file could not be loaded.", "zh-Hant": "無法載入分享的檔案。"],
            "share.error.timeout": ["en": "The file took too long to load. Please try again.", "zh-Hant": "檔案載入時間過長，請再試一次。"],
            "share.error.cancelled": ["en": "Sharing was cancelled.", "zh-Hant": "分享已取消。"],
            "share.error.empty": ["en": "This file is empty.", "zh-Hant": "這個檔案是空的。"],
            "share.error.tooLarge": ["en": "This file is too large to add.", "zh-Hant": "這個檔案太大，無法加入。"],
            "share.error.invalidFile": ["en": "This is not a valid PDF or supported image.", "zh-Hant": "這不是有效的 PDF 或支援的圖片。"],
            "share.error.storage": ["en": "The pattern could not be saved. Please try again.", "zh-Hant": "無法儲存織圖，請再試一次。"],
            "share.error.unexpected": ["en": "The pattern could not be added. Please try again.", "zh-Hant": "無法加入織圖，請再試一次。"],
        ]

        for (key, localizations) in expected {
            let entry = try #require(strings[key] as? [String: Any])
            let actualLocalizations = try #require(entry["localizations"] as? [String: Any])
            for (language, value) in localizations {
                let localization = try #require(actualLocalizations[language] as? [String: Any])
                let unit = try #require(localization["stringUnit"] as? [String: Any])
                #expect(unit["value"] as? String == value)
            }
        }
    }
}
