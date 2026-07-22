import Foundation
import Testing

@Suite struct LocalizationContractTests {
    private let requiredWatchTranslations = [
        "watch.projects.title": ["en": "Projects", "zh-Hant": "作品"],
        "watch.projects.empty": ["en": "No projects yet", "zh-Hant": "尚無作品"],
        "watch.project.completed": ["en": "Completed", "zh-Hant": "已完成"],
        "watch.sync.pending": ["en": "Waiting to sync", "zh-Hant": "待同步"],
        "watch.sync.error.projectCompleted": [
            "en": "Completed project; counters are read-only.",
            "zh-Hant": "作品已完成，計數器僅供查看",
        ],
        "watch.sync.error.projectMissing": [
            "en": "This project is no longer available.",
            "zh-Hant": "此作品已不存在",
        ],
        "watch.sync.error.counterMissing": [
            "en": "This counter is no longer available.",
            "zh-Hant": "此計數器已不存在",
        ],
        "watch.sync.error.unsupportedSchema": [
            "en": "Update KnitNote on iPhone and Apple Watch to continue syncing.",
            "zh-Hant": "請更新 iPhone 與 Apple Watch 上的 KnitNote 以繼續同步",
        ],
        "watch.sync.error.storageFailure": [
            "en": "Couldn't save this counter change.",
            "zh-Hant": "無法儲存此計數器變更",
        ],
        "watch.counter.incrementHint": ["en": "Increment by 1", "zh-Hant": "加 1"],
        "watch.counter.actions": ["en": "Counter actions", "zh-Hant": "計數器操作"],
        "watch.counter.decrement": ["en": "Decrease by 1", "zh-Hant": "減 1"],
        "watch.counter.reset": ["en": "Reset to zero", "zh-Hant": "歸零"],
        "watch.counter.cancel": ["en": "Cancel", "zh-Hant": "取消"],
    ]

    private let requiredYarnKeys = [
        "yarn.library.title",
        "yarn.create",
        "yarn.edit",
        "yarn.name",
        "yarn.photo",
        "yarn.brand",
        "yarn.series",
        "yarn.color",
        "yarn.colorCode",
        "yarn.dyeLot",
        "yarn.remainingBalls",
        "yarn.remainingGrams",
        "yarn.storageLocation",
        "yarn.notes",
        "yarn.linkedProjects",
        "yarn.delete",
        "yarn.delete.confirm",
        "yarn.empty.title",
        "yarn.empty.message",
        "yarn.inventory.balls",
        "yarn.inventory.grams",
        "yarn.error.invalidNumber",
        "yarn.error.negativeInventory",
        "yarn.photo.choose",
        "yarn.photo.replace",
        "yarn.photo.take",
        "yarn.photo.remove",
        "yarn.photo.loadFailed",
        "yarn.accessibility.photo",
        "yarn.accessibility.card",
        "common.retry",
        "yarn.error.photoInvalid",
        "yarn.error.archiveUnavailable",
        "yarn.error.linkedProjectsChanged",
        "yarn.error.saveRetry",
        "yarn.error.deleteFailed.title",
        "yarn.error.deleteFailed.message",
        "yarn.error.loadFailed.title",
        "yarn.error.loadFailed.message",
    ]

    private let requiredKeys = [
        "counter.accessibility.collapse",
        "counter.accessibility.decrement",
        "counter.accessibility.expand",
        "counter.accessibility.increment",
        "counter.accessibility.note",
        "counter.accessibility.rename",
        "counter.defaultName",
        "counter.rename",
        "counter.expand",
        "counter.collapse",
        "counter.increment",
        "counter.decrement",
    ]

    private let requiredJournalTranslations = [
        "journal.accessibility.add": ["en": "Add journal entry", "zh-Hant": "新增編織日記"],
        "journal.accessibility.fullPhoto": ["en": "Journal entry photo", "zh-Hant": "編織日記照片"],
        "journal.accessibility.photo": ["en": "Journal entry photo", "zh-Hant": "編織日記照片"],
        "journal.add": ["en": "Add journal entry", "zh-Hant": "新增日記"],
        "journal.add.title": ["en": "New journal entry", "zh-Hant": "新增日記"],
        "journal.caption.label": ["en": "Caption (optional)", "zh-Hant": "說明（選填）"],
        "journal.caption.placeholder": ["en": "Add a note about this progress", "zh-Hant": "記下這次進度"],
        "journal.delete": ["en": "Delete", "zh-Hant": "刪除"],
        "journal.delete.confirm.message": ["en": "This journal entry and its photos will be permanently deleted.", "zh-Hant": "這則日記與照片將永久刪除。"],
        "journal.delete.confirm.title": ["en": "Delete journal entry?", "zh-Hant": "刪除這則日記？"],
        "journal.detail.title": ["en": "Journal Entry", "zh-Hant": "日記內容"],
        "journal.edit": ["en": "Edit", "zh-Hant": "編輯"],
        "journal.edit.title": ["en": "Edit journal entry", "zh-Hant": "編輯日記"],
        "journal.empty.active": ["en": "Record the first progress on this project.", "zh-Hant": "記錄這件作品的第一個進度吧"],
        "journal.empty.completed": ["en": "No journal entries were recorded.", "zh-Hant": "這件作品沒有日記紀錄"],
        "journal.error.delete.title": ["en": "Couldn't delete journal entry", "zh-Hant": "無法刪除日記"],
        "journal.error.deleteFailed": ["en": "The journal entry couldn't be deleted. Please try again.", "zh-Hant": "無法刪除日記，請再試一次。"],
        "journal.error.invalidImage": ["en": "Choose a valid image and try again.", "zh-Hant": "請選擇有效的照片後再試一次。"],
        "journal.error.notFound": ["en": "This journal entry is no longer available.", "zh-Hant": "這則日記已無法使用。"],
        "journal.error.projectCompleted": ["en": "This completed project's journal is read-only.", "zh-Hant": "作品已完成，編織日記僅供查看"],
        "journal.error.save.title": ["en": "Couldn't save journal entry", "zh-Hant": "無法儲存日記"],
        "journal.error.saveFailed": ["en": "The journal entry couldn't be saved. Please try again.", "zh-Hant": "無法儲存日記，請再試一次。"],
        "journal.photo.camera": ["en": "Camera", "zh-Hant": "相機"],
        "journal.photo.library": ["en": "Photo Library", "zh-Hant": "照片圖庫"],
        "journal.photo.loadFailed": ["en": "Couldn't load photo", "zh-Hant": "無法載入照片"],
        "journal.photo.loading": ["en": "Loading photo", "zh-Hant": "正在載入照片"],
        "journal.photo.select": ["en": "Select a photo", "zh-Hant": "選擇照片"],
        "journal.photo.unavailable": ["en": "Photo unavailable", "zh-Hant": "無法載入照片"],
        "journal.readOnly.completed": ["en": "This completed project's journal is read-only.", "zh-Hant": "作品已完成，編織日記僅供查看"],
        "journal.saving": ["en": "Saving journal entry", "zh-Hant": "正在儲存日記"],
        "journal.title": ["en": "Knitting Journal", "zh-Hant": "編織日記"],
        "journal.card.accessibility.withCaption.format": ["en": "Journal entry, %1$@, %2$@", "zh-Hant": "編織日記，%1$@，%2$@"],
        "journal.card.accessibility.withCaption.loading.format": ["en": "Journal entry, photo loading, %1$@, %2$@", "zh-Hant": "編織日記，照片載入中，%1$@，%2$@"],
        "journal.card.accessibility.withCaption.unavailable.format": ["en": "Journal entry, photo unavailable, %1$@, %2$@", "zh-Hant": "編織日記，照片無法載入，%1$@，%2$@"],
        "journal.card.accessibility.withoutCaption.format": ["en": "Journal entry, %@", "zh-Hant": "編織日記，%@"],
        "journal.card.accessibility.withoutCaption.loading.format": ["en": "Journal entry, photo loading, %@", "zh-Hant": "編織日記，照片載入中，%@"],
        "journal.card.accessibility.withoutCaption.unavailable.format": ["en": "Journal entry, photo unavailable, %@", "zh-Hant": "編織日記，照片無法載入，%@"],
    ]

    private let requiredProjectToolTranslations = [
        "project.tool.section": ["en": "Tools", "zh-Hant": "使用工具"],
        "project.tool.type": ["en": "Tool type", "zh-Hant": "工具類型"],
        "project.tool.type.none": ["en": "Not set", "zh-Hant": "未設定"],
        "project.tool.type.crochetHook": ["en": "Crochet hook", "zh-Hant": "鉤針"],
        "project.tool.type.knittingNeedles": ["en": "Knitting needles", "zh-Hant": "棒針"],
        "project.tool.type.other": ["en": "Other", "zh-Hant": "其他"],
        "project.tool.size": ["en": "Size", "zh-Hant": "尺寸"],
        "project.tool.notes": ["en": "Notes", "zh-Hant": "備註"],
    ]

    private let requiredGaugeFormatTranslations = [
        "calculator.gauge.recommendation.format": [
            "en": "Recommended: %lld",
            "zh-Hant": "建議數量：%lld",
        ],
        "calculator.gauge.stitches.recommendation.format": [
            "en": "Recommended stitches: %lld",
            "zh-Hant": "建議針數：%lld",
        ],
        "calculator.gauge.rows.recommendation.format": [
            "en": "Recommended rows: %lld",
            "zh-Hant": "建議排數：%lld",
        ],
        "calculator.gauge.stitches.density.centimeters.format": [
            "en": "%@ stitches per centimeter",
            "zh-Hant": "每公分 %@ 針",
        ],
        "calculator.gauge.stitches.density.inches.format": [
            "en": "%@ stitches per inch",
            "zh-Hant": "每英吋 %@ 針",
        ],
        "calculator.gauge.rows.density.centimeters.format": [
            "en": "%@ rows per centimeter",
            "zh-Hant": "每公分 %@ 排",
        ],
        "calculator.gauge.rows.density.inches.format": [
            "en": "%@ rows per inch",
            "zh-Hant": "每英吋 %@ 排",
        ],
    ]

    private let requiredAdjustmentTranslations = [
        "calculator.adjustment.title": ["en": "Even Increase / Decrease", "zh-Hant": "等距加針／減針"],
        "calculator.adjustment.input.title": ["en": "Stitch Counts", "zh-Hant": "針數"],
        "calculator.adjustment.current": ["en": "Current stitches", "zh-Hant": "目前針數"],
        "calculator.adjustment.target": ["en": "Target stitches", "zh-Hant": "目標針數"],
        "calculator.adjustment.reservesEdgeStitches": ["en": "Reserve one edge stitch on each side", "zh-Hant": "左右各保留 1 針"],
        "calculator.adjustment.validation.positiveInteger": ["en": "Enter a whole number greater than 0.", "zh-Hant": "請輸入大於 0 的整數。"],
        "calculator.adjustment.summary.unchanged": ["en": "No increases or decreases are needed.", "zh-Hant": "不需要加針或減針。"],
        "calculator.adjustment.edgeSummary": ["en": "One edge stitch is reserved on each side.", "zh-Hant": "左右各保留 1 針。"],
        "calculator.adjustment.steps.show": ["en": "Show complete steps", "zh-Hant": "查看完整步驟"],
        "calculator.adjustment.step.increaseOne": ["en": "Increase 1 stitch", "zh-Hant": "加 1 針"],
        "calculator.adjustment.step.decreaseOne": ["en": "Decrease the next 2 stitches into 1", "zh-Hant": "將接下來 2 針併成 1 針"],
        "calculator.adjustment.step.knit.singular": ["en": "Knit 1 stitch", "zh-Hant": "織 1 針"],
        "calculator.adjustment.summary.increase.singular": ["en": "Increase 1 stitch evenly.", "zh-Hant": "平均加 1 針。"],
        "calculator.adjustment.summary.decrease.singular": ["en": "Decrease 1 stitch evenly.", "zh-Hant": "平均減 1 針。"],
        "calculator.adjustment.interval.increase.singular": ["en": "Increase after every 1 stitch.", "zh-Hant": "每織 1 針加 1 針。"],
        "calculator.adjustment.interval.decrease.singular": ["en": "Decrease after every 1 stitch.", "zh-Hant": "每織 1 針減 1 針。"],
        "calculator.adjustment.interval.decrease.adjacent": ["en": "Decrease adjacent stitches throughout the row.", "zh-Hant": "整排連續將相鄰 2 針併成 1 針。"],
        "calculator.adjustment.failure.invalidCounts": ["en": "Enter valid current and target stitch counts.", "zh-Hant": "請輸入有效的目前針數與目標針數。"],
        "calculator.adjustment.failure.cannotPreserveEdges": ["en": "This adjustment cannot preserve one edge stitch on each side.", "zh-Hant": "這次調整無法左右各保留 1 針。"],
        "calculator.adjustment.failure.requiresMultipleRows": ["en": "This adjustment cannot be completed evenly in one row. Divide it across multiple rows.", "zh-Hant": "這次調整無法在一排內平均完成，請分成多排進行。"],
        "calculator.adjustment.mode.oneRow": ["en": "One Row", "zh-Hant": "單排分配"],
        "calculator.adjustment.mode.acrossRows": ["en": "Across Rows", "zh-Hant": "跨段分配"],
        "calculator.adjustment.rows.input.title": ["en": "Row Distribution", "zh-Hant": "跨段分配"],
        "calculator.adjustment.rows.operation": ["en": "Operation", "zh-Hant": "操作"],
        "calculator.adjustment.rows.operation.increase": ["en": "Increase", "zh-Hant": "加針"],
        "calculator.adjustment.rows.operation.decrease": ["en": "Decrease", "zh-Hant": "減針"],
        "calculator.adjustment.rows.totalRows": ["en": "Total rows", "zh-Hant": "總段數"],
        "calculator.adjustment.rows.totalStitches": ["en": "Total stitches to change", "zh-Hant": "總加減針數"],
        "calculator.adjustment.rows.style": ["en": "Adjustment style", "zh-Hant": "每次做法"],
        "calculator.adjustment.rows.style.singleSide": ["en": "1 stitch each time", "zh-Hant": "每次單側 1 針"],
        "calculator.adjustment.rows.style.bothSides": ["en": "1 stitch on each side", "zh-Hant": "每次左右各 1 針"],
        "calculator.adjustment.rows.details.show": ["en": "Show adjustment rows", "zh-Hant": "查看調整段數"],
        "calculator.adjustment.rows.interval.everyRow": ["en": "Every row", "zh-Hant": "每段"],
        "calculator.adjustment.rows.failure.symmetricEven": ["en": "For matching changes on both sides, enter an even number of stitches.", "zh-Hant": "左右對稱加減針時，總針數請輸入偶數。"],
        "calculator.adjustment.rows.failure.insufficientRows": ["en": "There are not enough rows to distribute these changes once per row.", "zh-Hant": "指定段數不足，無法以每段最多一次平均完成。"],
    ]

    private let requiredAdjustmentFormatTranslations = [
        "calculator.adjustment.summary.increase.format": ["en": "Increase %lld stitches evenly.", "zh-Hant": "平均加 %lld 針。"],
        "calculator.adjustment.summary.decrease.format": ["en": "Decrease %lld stitches evenly.", "zh-Hant": "平均減 %lld 針。"],
        "calculator.adjustment.interval.increase.format": ["en": "Increase after every %@ stitches.", "zh-Hant": "每織 %@ 針加 1 針。"],
        "calculator.adjustment.interval.decrease.format": ["en": "Decrease after every %@ stitches.", "zh-Hant": "每織 %@ 針減 1 針。"],
        "calculator.adjustment.interval.range.format": ["en": "%@–%@", "zh-Hant": "%@～%@"],
        "calculator.adjustment.interval.increase.single.format": ["en": "Increase after every %lld stitches.", "zh-Hant": "每織 %lld 針加 1 針。"],
        "calculator.adjustment.interval.decrease.single.format": ["en": "Decrease after every %lld stitches.", "zh-Hant": "每織 %lld 針減 1 針。"],
        "calculator.adjustment.accessibility.summary.full.format": ["en": "%@ %@ %@", "zh-Hant": "%@ %@ %@"],
        "calculator.adjustment.accessibility.summary.interval.format": ["en": "%@ %@", "zh-Hant": "%@ %@"],
        "calculator.adjustment.accessibility.summary.edge.format": ["en": "%@ %@", "zh-Hant": "%@ %@"],
        "calculator.adjustment.step.edge.format": ["en": "Knit %lld edge stitch", "zh-Hant": "織 %lld 針邊針"],
        "calculator.adjustment.step.knit.format": ["en": "Knit %lld stitches", "zh-Hant": "織 %lld 針"],
        "calculator.adjustment.failure.exceedsSupportedLimit.format": ["en": "Enter 100,000 stitches or fewer (maximum %lld).", "zh-Hant": "請輸入不超過 100,000 針（上限 %lld）。"],
        "calculator.adjustment.rows.summary.increase.singleSide.exact.format": ["en": "%@, increase 1 stitch on one side. Adjustment rows: %lld.", "zh-Hant": "%@，單側加 1 針；調整段數：%lld。"],
        "calculator.adjustment.rows.summary.increase.singleSide.range.format": ["en": "%@, increase 1 stitch on one side. Adjustment rows: %lld.", "zh-Hant": "%@，單側加 1 針；調整段數：%lld。"],
        "calculator.adjustment.rows.summary.increase.bothSides.exact.format": ["en": "%@, increase 1 stitch on each side. Adjustment rows: %lld.", "zh-Hant": "%@，左右各加 1 針；調整段數：%lld。"],
        "calculator.adjustment.rows.summary.increase.bothSides.range.format": ["en": "%@, increase 1 stitch on each side. Adjustment rows: %lld.", "zh-Hant": "%@，左右各加 1 針；調整段數：%lld。"],
        "calculator.adjustment.rows.summary.decrease.singleSide.exact.format": ["en": "%@, decrease 1 stitch on one side. Adjustment rows: %lld.", "zh-Hant": "%@，單側減 1 針；調整段數：%lld。"],
        "calculator.adjustment.rows.summary.decrease.singleSide.range.format": ["en": "%@, decrease 1 stitch on one side. Adjustment rows: %lld.", "zh-Hant": "%@，單側減 1 針；調整段數：%lld。"],
        "calculator.adjustment.rows.summary.decrease.bothSides.exact.format": ["en": "%@, decrease 1 stitch on each side. Adjustment rows: %lld.", "zh-Hant": "%@，左右各減 1 針；調整段數：%lld。"],
        "calculator.adjustment.rows.summary.decrease.bothSides.range.format": ["en": "%@, decrease 1 stitch on each side. Adjustment rows: %lld.", "zh-Hant": "%@，左右各減 1 針；調整段數：%lld。"],
        "calculator.adjustment.rows.interval.exact.format": ["en": "Every %lld rows", "zh-Hant": "每 %lld 段"],
        "calculator.adjustment.rows.interval.range.format": ["en": "About every %@ rows", "zh-Hant": "約每 %@ 段"],
        "calculator.adjustment.rows.range.format": ["en": "%lld–%lld", "zh-Hant": "%lld～%lld"],
        "calculator.adjustment.rows.detail.format": ["en": "Row %lld.", "zh-Hant": "第 %lld 段。"],
        "calculator.adjustment.rows.failure.exceedsSupportedLimit.format": ["en": "Enter 100,000 or fewer (maximum %lld).", "zh-Hant": "請輸入不超過 100,000（上限 %lld）。"],
    ]

    @Test func counterStringsHaveEnglishAndTraditionalChineseTranslations() throws {
        let strings = try catalogStrings()

        for key in requiredKeys {
            let localizations = try #require(strings[key] as? [String: Any])
            let translations = try #require(localizations["localizations"] as? [String: Any])
            for language in ["en", "zh-Hant"] {
                let translation = try #require(translations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                #expect(!(try #require(stringUnit["value"] as? String)).isEmpty)
            }
        }
    }

    @Test func watchStringsHaveCompleteExactEnglishAndTraditionalChineseCopy() throws {
        let strings = try watchCatalogStrings()

        for (key, expectedValues) in requiredWatchTranslations {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for (language, expectedValue) in expectedValues {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                #expect(stringUnit["value"] as? String == expectedValue)
            }
        }
    }

    @Test func yarnStringsHaveEnglishAndTraditionalChineseTranslations() throws {
        let strings = try catalogStrings()

        for key in requiredYarnKeys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hant"] {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                #expect(!(try #require(stringUnit["value"] as? String)).isEmpty)
            }
        }
    }

    @Test func journalStringsHaveCompleteExactEnglishAndTraditionalChineseCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedValues) in requiredJournalTranslations {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for (language, expectedValue) in expectedValues {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                #expect(stringUnit["value"] as? String == expectedValue)
            }
        }
    }

    @Test func cameraPurposeDescriptionMentionsProjectsAndJournalEntriesInBothLanguages() throws {
        let catalogURL = repositoryRoot.appending(
            path: "KnitNote/Localization/InfoPlist.xcstrings"
        )
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let camera = try #require(strings["NSCameraUsageDescription"] as? [String: Any])
        let localizations = try #require(camera["localizations"] as? [String: Any])

        #expect(
            try infoPlistLocalizedValue("en", localizations: localizations)
                == "Take photos for your knitting projects and journal entries."
        )
        #expect(
            try infoPlistLocalizedValue("zh-Hant", localizations: localizations)
                == "拍攝照片加入你的編織作品與編織日記。"
        )
    }

    @Test func journalCardAccessibilityFormatsKeepTheirExactPlaceholderContracts() throws {
        let strings = try catalogStrings()

        for language in ["en", "zh-Hant"] {
            #expect(
                try localizedValue(
                    "journal.card.accessibility.withCaption.format",
                    language: language,
                    strings: strings
                ).components(separatedBy: "%1$@").count == 2
            )
            #expect(
                try localizedValue(
                    "journal.card.accessibility.withCaption.format",
                    language: language,
                    strings: strings
                ).components(separatedBy: "%2$@").count == 2
            )
            #expect(
                try localizedValue(
                    "journal.card.accessibility.withoutCaption.format",
                    language: language,
                    strings: strings
                ).components(separatedBy: "%@").count == 2
            )
            for key in [
                "journal.card.accessibility.withCaption.loading.format",
                "journal.card.accessibility.withCaption.unavailable.format",
            ] {
                let value = try localizedValue(key, language: language, strings: strings)
                #expect(value.components(separatedBy: "%1$@").count == 2)
                #expect(value.components(separatedBy: "%2$@").count == 2)
            }
            for key in [
                "journal.card.accessibility.withoutCaption.loading.format",
                "journal.card.accessibility.withoutCaption.unavailable.format",
            ] {
                #expect(
                    try localizedValue(key, language: language, strings: strings)
                        .components(separatedBy: "%@").count == 2
                )
            }
        }
    }

    @Test func journalSourceCatalogAndContractKeysStayInLockstep() throws {
        let strings = try catalogStrings()
        let expectedKeys = Set(requiredJournalTranslations.keys)
        let catalogKeys = Set(strings.keys.filter { $0.hasPrefix("journal.") })

        #expect(try journalSourceKeys() == expectedKeys)
        #expect(catalogKeys == expectedKeys)
    }

    @Test func projectToolStringsHaveRequiredEnglishAndTraditionalChineseTranslations() throws {
        let strings = try catalogStrings()

        for (key, expectedTranslations) in requiredProjectToolTranslations {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for (language, expectedValue) in expectedTranslations {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                #expect(stringUnit["value"] as? String == expectedValue)
            }
        }
    }

    @Test func gaugeCalculatorStringsHaveTraditionalChineseAndEnglish() throws {
        let keys = [
            "calculator.tools.title",
            "calculator.gauge.title",
            "calculator.gauge.unit",
            "calculator.gauge.unit.centimeters",
            "calculator.gauge.unit.inches",
            "calculator.gauge.stitches",
            "calculator.gauge.rows.optional",
            "calculator.gauge.sampleWidth",
            "calculator.gauge.sampleStitches",
            "calculator.gauge.targetWidth",
            "calculator.gauge.sampleHeight",
            "calculator.gauge.sampleRows",
            "calculator.gauge.targetHeight",
            "calculator.gauge.density",
            "calculator.gauge.exact",
            "calculator.gauge.recommended",
            "calculator.gauge.stitches.recommendation",
            "calculator.gauge.rows.recommendation",
            "calculator.validation.positive",
        ] + Array(requiredGaugeFormatTranslations.keys)
        let strings = try catalogStrings()

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hant"] {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                #expect(!(try #require(stringUnit["value"] as? String)).isEmpty)
            }
        }
    }

    @Test func gaugeCalculatorNamedFormatsHaveExactCopyAndOnePlaceholder() throws {
        let strings = try catalogStrings()

        for (key, expectedValues) in requiredGaugeFormatTranslations {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for (language, expectedValue) in expectedValues {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                let value = try #require(stringUnit["value"] as? String)
                #expect(value == expectedValue)
                let placeholder = key.contains("density") ? "%@" : "%lld"
                #expect(value.components(separatedBy: placeholder).count == 2)
            }
        }
    }

    @Test func gaugeCalculatorStringsUseRequiredEnglishAndTraditionalChineseCopy() throws {
        let expectedTranslations = [
            "calculator.tools.title": ["en": "Knitting Calculators", "zh-Hant": "編織計算工具"],
            "calculator.gauge.title": ["en": "Gauge Calculator", "zh-Hant": "密度計算"],
            "calculator.gauge.unit.centimeters": ["en": "Centimeters", "zh-Hant": "公分"],
            "calculator.gauge.unit.inches": ["en": "Inches", "zh-Hant": "英吋"],
            "calculator.gauge.stitches": ["en": "Stitch Calculation", "zh-Hant": "針數計算"],
            "calculator.gauge.rows.optional": ["en": "Row Calculation (Optional)", "zh-Hant": "排數計算（選填）"],
            "calculator.validation.positive": ["en": "Enter a value greater than 0.", "zh-Hant": "請輸入大於 0 的數值。"],
        ]
        let strings = try catalogStrings()

        #expect(strings["calculator.gauge.validation"] == nil)

        for (key, expectedValues) in expectedTranslations {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for (language, expectedValue) in expectedValues {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                let value = try #require(stringUnit["value"] as? String)
                #expect(value == expectedValue)
                if key.hasSuffix(" %lld") {
                    #expect(value.components(separatedBy: "%lld").count == 2)
                }
            }
        }
    }

    @Test func evenAdjustmentStringsUseRequiredEnglishAndTraditionalChineseCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedValues) in requiredAdjustmentTranslations.merging(
            requiredAdjustmentFormatTranslations,
            uniquingKeysWith: { _, new in new }
        ) {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for (language, expectedValue) in expectedValues {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                #expect(stringUnit["value"] as? String == expectedValue)
            }
        }
    }

    @Test func evenAdjustmentFormatsKeepTheirPlaceholderContracts() throws {
        let strings = try catalogStrings()
        let integerFormats = [
            "calculator.adjustment.summary.increase.format",
            "calculator.adjustment.summary.decrease.format",
            "calculator.adjustment.step.edge.format",
            "calculator.adjustment.step.knit.format",
            "calculator.adjustment.failure.exceedsSupportedLimit.format",
            "calculator.adjustment.interval.increase.single.format",
            "calculator.adjustment.interval.decrease.single.format",
        ]
        let singleObjectFormats = [
            "calculator.adjustment.interval.increase.format",
            "calculator.adjustment.interval.decrease.format",
        ]

        for language in ["en", "zh-Hant"] {
            for key in integerFormats {
                #expect(try localizedValue(key, language: language, strings: strings).components(separatedBy: "%lld").count == 2)
            }
            for key in singleObjectFormats {
                #expect(try localizedValue(key, language: language, strings: strings).components(separatedBy: "%@").count == 2)
            }
            #expect(try localizedValue("calculator.adjustment.interval.range.format", language: language, strings: strings).components(separatedBy: "%@").count == 3)
            #expect(try localizedValue("calculator.adjustment.accessibility.summary.full.format", language: language, strings: strings).components(separatedBy: "%@").count == 4)
            #expect(try localizedValue("calculator.adjustment.accessibility.summary.interval.format", language: language, strings: strings).components(separatedBy: "%@").count == 3)
            #expect(try localizedValue("calculator.adjustment.accessibility.summary.edge.format", language: language, strings: strings).components(separatedBy: "%@").count == 3)
            #expect(try localizedValue("calculator.adjustment.failure.exceedsSupportedLimit.format", language: language, strings: strings).contains("100,000"))
        }
    }

    @Test func rowAdjustmentFormatsKeepTheirPlaceholderContracts() throws {
        let strings = try catalogStrings()
        let summaryFormats = requiredAdjustmentFormatTranslations.keys.filter {
            $0.hasPrefix("calculator.adjustment.rows.summary.")
        }
        let integerFormats = [
            "calculator.adjustment.rows.interval.exact.format",
            "calculator.adjustment.rows.detail.format",
            "calculator.adjustment.rows.failure.exceedsSupportedLimit.format",
        ]

        for language in ["en", "zh-Hant"] {
            for key in summaryFormats {
                let value = try localizedValue(key, language: language, strings: strings)
                #expect(value.components(separatedBy: "%@").count == 2)
                #expect(value.components(separatedBy: "%lld").count == 2)
            }
            for key in integerFormats {
                #expect(try localizedValue(key, language: language, strings: strings).components(separatedBy: "%lld").count == 2)
            }
            #expect(try localizedValue("calculator.adjustment.rows.interval.range.format", language: language, strings: strings).components(separatedBy: "%@").count == 2)
            #expect(try localizedValue("calculator.adjustment.rows.range.format", language: language, strings: strings).components(separatedBy: "%lld").count == 3)
            #expect(try localizedValue("calculator.adjustment.rows.failure.exceedsSupportedLimit.format", language: language, strings: strings).contains("100,000"))
        }
    }

    @Test func rowAdjustmentSingleEventCopyAvoidsPluralTimesAndRows() throws {
        let strings = try catalogStrings()

        for language in ["en", "zh-Hant"] {
            let interval = try localizedValue(
                "calculator.adjustment.rows.interval.everyRow",
                language: language,
                strings: strings
            )
            let format = try localizedValue(
                "calculator.adjustment.rows.summary.increase.singleSide.exact.format",
                language: language,
                strings: strings
            )
            let summary = String.localizedStringWithFormat(format, interval, 1)

            #expect(!summary.contains("1 times"))
            #expect(!summary.contains("1 rows"))
        }
    }

    @Test func rowAdjustmentSourceCatalogAndContractKeysStayInLockstep() throws {
        let strings = try catalogStrings()
        let expectedKeys = Set(
            requiredAdjustmentTranslations.keys
                .filter { $0.hasPrefix("calculator.adjustment.mode.") || $0.hasPrefix("calculator.adjustment.rows.") }
            + requiredAdjustmentFormatTranslations.keys
                .filter { $0.hasPrefix("calculator.adjustment.rows.") }
        )
        let catalogKeys = Set(strings.keys.filter {
            $0.hasPrefix("calculator.adjustment.mode.") || $0.hasPrefix("calculator.adjustment.rows.")
        })

        #expect(expectedKeys.count == 28)
        #expect(try rowAdjustmentSourceKeys() == expectedKeys)
        #expect(catalogKeys == expectedKeys)
    }

    @Test func yarnAccessibilityCardFormatsTheYarnNameColorAndInventory() throws {
        let strings = try catalogStrings()
        let entry = try #require(strings["yarn.accessibility.card"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])

        for language in ["en", "zh-Hant"] {
            let translation = try #require(localizations[language] as? [String: Any])
            let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
            let value = try #require(stringUnit["value"] as? String)
            #expect(value.components(separatedBy: "%@").count == 4)
        }
    }

    @Test func defaultCounterNameFormatsAnOrdinalInBothSupportedLanguages() throws {
        let strings = try catalogStrings()
        let entry = try #require(strings["counter.defaultName"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])

        for language in ["en", "zh-Hant"] {
            let translation = try #require(localizations[language] as? [String: Any])
            let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
            let value = try #require(stringUnit["value"] as? String)
            #expect(value.contains("%lld"))
        }
    }

    @Test func counterAccessibilityActionsFormatCounterIdentityAndCurrentValue() throws {
        let strings = try catalogStrings()
        let keys = requiredKeys.filter { $0.hasPrefix("counter.accessibility.") }

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hant"] {
                let translation = try #require(localizations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                let value = try #require(stringUnit["value"] as? String)
                #expect(value.contains("%@"))
                #expect(value.contains("%lld"))
            }
        }
    }

    @Test func counterNameResolverUsesTheSuppliedSwiftUILocale() throws {
        let source = try projectSource(named: "ProjectCounterName")

        #expect(source.contains("func projectCounterDisplayName(_ counter: ProjectCounter, locale: Locale)"))
        #expect(source.contains("String(localized: \"counter.defaultName\", locale: locale)"))
        #expect(source.contains("locale: locale,"))
    }

    @Test func editingAnUntouchedDefaultNameRestoresTheLocalizedDefault() throws {
        let source = try projectSource(named: "EditCounterNameView")

        #expect(source.contains("@Environment(\\.locale) private var locale"))
        #expect(source.contains("@State private var hasEditedName = false"))
        #expect(source.contains("counter.customName == nil && !hasEditedName"))
        #expect(source.contains("counter.customName == nil && !hasEditedName"))
        #expect(source.contains("onDone(savedName, value)"))
    }

    @Test func traditionalChineseUsesKnittingPatternTerminology() throws {
        let strings = try catalogStrings()
        let values = strings.values.compactMap { entry -> String? in
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let translation = localizations["zh-Hant"] as? [String: Any],
                  let stringUnit = translation["stringUnit"] as? [String: Any]
            else { return nil }
            return stringUnit["value"] as? String
        }
        let forbidden = values.filter { $0.contains("圖解") }
        #expect(forbidden.isEmpty)
        #expect(try localizedValue("patterns.title", language: "zh-Hant", strings: strings) == "織圖")
        #expect(try localizedValue("patterns.open", language: "zh-Hant", strings: strings) == "織圖")
        #expect(try localizedValue("patterns.add", language: "zh-Hant", strings: strings) == "加入織圖")
    }

    private func catalogStrings() throws -> [String: Any] {
        let root = repositoryRoot
        let catalogURL = root.appending(path: "KnitNote/Localization/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(catalog["strings"] as? [String: Any])
    }

    private func watchCatalogStrings() throws -> [String: Any] {
        let catalogURL = repositoryRoot.appending(path: "KnitNoteWatch/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(catalog["strings"] as? [String: Any])
    }

    private func localizedValue(
        _ key: String,
        language: String,
        strings: [String: Any]
    ) throws -> String {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let translation = try #require(localizations[language] as? [String: Any])
        let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
        return try #require(stringUnit["value"] as? String)
    }

    private func infoPlistLocalizedValue(
        _ language: String,
        localizations: [String: Any]
    ) throws -> String {
        let localization = try #require(localizations[language] as? [String: Any])
        let stringUnit = try #require(localization["stringUnit"] as? [String: Any])
        return try #require(stringUnit["value"] as? String)
    }

    private func journalSourceKeys() throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: #"journal\.[A-Za-z0-9._-]+"#)
        let sourceFiles = [
            "ProjectJournalSection",
            "EditProjectJournalEntryView",
            "ProjectJournalEntryDetailView",
            "JournalPhotoPicker",
        ]

        return try Set(sourceFiles.flatMap { name in
            let source = try projectSource(named: name)
            let range = NSRange(source.startIndex..., in: source)
            return expression.matches(in: source, range: range).compactMap { match in
                Range(match.range, in: source).map { String(source[$0]) }
            }
        })
    }

    private func rowAdjustmentSourceKeys() throws -> Set<String> {
        let expression = try NSRegularExpression(
            pattern: #"calculator\.adjustment\.(?:mode|rows)\.[A-Za-z0-9._-]+"#
        )
        let sourceFiles = [
            "KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift",
            "KnitNote/Calculators/RowIntervalAdjustmentView.swift",
        ]

        return try Set(sourceFiles.flatMap { path in
            let source = try String(
                contentsOf: repositoryRoot.appending(path: path),
                encoding: .utf8
            )
            let range = NSRange(source.startIndex..., in: source)
            return expression.matches(in: source, range: range).compactMap { match in
                Range(match.range, in: source).map { String(source[$0]) }
            }
        })
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func projectSource(named name: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appending(path: "KnitNote/Projects/\(name).swift"),
            encoding: .utf8
        )
    }
}
