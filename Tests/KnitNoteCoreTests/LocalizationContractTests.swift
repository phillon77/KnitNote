import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct StringCatalogLocalizationContractTests {
    @Test func version140LocalizationContractNamesTheCompleteLanguageDomain() {
        #expect(
            SupportedLocalization.v140Identifiers
                == ["en", "zh-Hant", "zh-Hans", "de", "fr", "ja"]
        )
    }

    @Test func completeCatalogAcceptsEveryVersion140LanguageAndMatchingFormatTokens() throws {
        let catalog = try makeCatalogFixture()

        try assertCompleteCatalog(
            at: catalog,
            requiredLanguages: SupportedLocalization.v140Identifiers
        )
    }

    @Test func completeCatalogAcceptsReorderedNumberedArguments() throws {
        let localizations: [String: Any] = [
            "en": fixtureLocalization(value: "%1$lld items by %2$@"),
            "zh-Hant": fixtureLocalization(value: "%1$lld 項，作者 %2$@"),
            "zh-Hans": fixtureLocalization(value: "%1$lld 项，作者 %2$@"),
            "de": fixtureLocalization(value: "%1$lld Elemente von %2$@"),
            "fr": fixtureLocalization(value: "%1$lld articles par %2$@"),
            "ja": fixtureLocalization(value: "%2$@ による %1$lld 件"),
        ]
        let catalog = try makeCatalogFixture(localizations: localizations)

        try assertCompleteCatalog(
            at: catalog,
            requiredLanguages: SupportedLocalization.v140Identifiers
        )
    }

    @Test func completeCatalogRejectsAMissingLanguage() throws {
        var localizations = completeFixtureLocalizations()
        localizations.removeValue(forKey: "zh-Hans")
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.missingLanguage(
                key: "feature.count.format",
                language: "zh-Hans"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v140Identifiers
            )
        }
    }

    @Test func completeCatalogRejectsAnEmptyValue() throws {
        var localizations = completeFixtureLocalizations()
        localizations["de"] = fixtureLocalization(value: "   ")
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.emptyValue(
                key: "feature.count.format",
                language: "de"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v140Identifiers
            )
        }
    }

    @Test func completeCatalogRejectsAStaleValue() throws {
        var localizations = completeFixtureLocalizations()
        localizations["ja"] = fixtureLocalization(value: "%lld 件", state: "stale")
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.staleValue(
                key: "feature.count.format",
                language: "ja"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v140Identifiers
            )
        }
    }

    @Test func completeCatalogRejectsADottedKeyPlaceholder() throws {
        var localizations = completeFixtureLocalizations()
        localizations["fr"] = fixtureLocalization(value: "feature.count.format")
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.staleValue(
                key: "feature.count.format",
                language: "fr"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v140Identifiers
            )
        }
    }

    @Test func completeCatalogRejectsAChangedArgumentType() throws {
        var localizations = completeFixtureLocalizations()
        localizations["fr"] = fixtureLocalization(value: "%@ articles")
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.formatMismatch(
                key: "feature.count.format",
                language: "fr",
                path: "<direct>"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v140Identifiers
            )
        }
    }

    @Test func catalogOracleRejectsADeletedSourceKey() throws {
        let catalog = try makeCatalogFixture()
        let oracle = try makeCatalogOracleFixture(
            entries: [
                "feature.count.format": oracleEntry(effectiveEnglish: "%lld items"),
                "feature.secondary": oracleEntry(effectiveEnglish: "Secondary"),
            ]
        )

        #expect(throws: StringCatalogContractError.oracleMismatch(catalog: "fixture")) {
            try assertCatalogMatchesOracle(
                at: catalog,
                oracleAt: oracle,
                catalogName: "fixture",
                expectedSourceCommit: "f0116e0"
            )
        }
    }

    @Test func catalogOracleRejectsAnEffectiveEnglishMutation() throws {
        var localizations = completeFixtureLocalizations()
        localizations["en"] = fixtureLocalization(value: "%lld changed items")
        let catalog = try makeCatalogFixture(localizations: localizations)
        let oracle = try makeCatalogOracleFixture()

        #expect(throws: StringCatalogContractError.oracleMismatch(catalog: "fixture")) {
            try assertCatalogMatchesOracle(
                at: catalog,
                oracleAt: oracle,
                catalogName: "fixture",
                expectedSourceCommit: "f0116e0"
            )
        }
    }

    @Test func catalogOracleRejectsASourceMetadataMutation() throws {
        let catalog = try makeCatalogFixture(
            entryMetadata: ["comment": "Mutated source intent"]
        )
        let oracle = try makeCatalogOracleFixture()

        #expect(throws: StringCatalogContractError.oracleMismatch(catalog: "fixture")) {
            try assertCatalogMatchesOracle(
                at: catalog,
                oracleAt: oracle,
                catalogName: "fixture",
                expectedSourceCommit: "f0116e0"
            )
        }
    }

    @Test func completeCatalogRejectsANonTranslatedTargetState() throws {
        var localizations = completeFixtureLocalizations()
        localizations["de"] = fixtureLocalization(value: "%lld Elemente", state: "new")
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.nonTranslatedValue(
                key: "feature.count.format",
                language: "de",
                path: "<direct>",
                state: "new"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v140Identifiers
            )
        }
    }

    @Test func completeCatalogRejectsFormatTokensMovedBetweenPluralCategories() throws {
        let matching = fixturePluralLocalization(
            one: "%lld item",
            other: "%@ items"
        )
        let otherOnly = fixtureOtherOnlyPluralLocalization(other: "%@ items")
        var localizations: [String: Any] = [
            "en": matching,
            "zh-Hant": otherOnly,
            "zh-Hans": otherOnly,
            "de": matching,
            "fr": matching,
            "ja": otherOnly,
        ]
        localizations["de"] = fixturePluralLocalization(
            one: "%@ Element",
            other: "%lld Elemente"
        )
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.formatMismatch(
                key: "feature.count.format",
                language: "de",
                path: "variations.plural.one"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v140Identifiers
            )
        }
    }

    @Test(arguments: ["de", "fr"])
    func completeCatalogRejectsMissingRequiredPluralOne(language: String) throws {
        let westernPlural = fixturePluralLocalization(
            one: "%lld item",
            other: "%lld items"
        )
        let otherOnlyPlural = fixtureOtherOnlyPluralLocalization(other: "%lld items")
        var localizations: [String: Any] = [
            "en": westernPlural,
            "zh-Hant": otherOnlyPlural,
            "zh-Hans": otherOnlyPlural,
            "de": westernPlural,
            "fr": westernPlural,
            "ja": otherOnlyPlural,
        ]
        var mutated = try #require(localizations[language] as? [String: Any])
        var variations = try #require(mutated["variations"] as? [String: Any])
        var plural = try #require(variations["plural"] as? [String: Any])
        plural.removeValue(forKey: "one")
        variations["plural"] = plural
        mutated["variations"] = variations
        localizations[language] = mutated
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.missingVariationPath(
                key: "feature.count.format",
                language: language,
                path: "variations.plural.one"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v140Identifiers
            )
        }
    }

    @Test(arguments: ["nb", "sv", "fi", "da", "el"])
    func completeCatalogRejectsMissingVersion141PluralOne(language: String) throws {
        var localizations = version141PluralFixtureLocalizations()
        var mutated = try #require(localizations[language] as? [String: Any])
        var variations = try #require(mutated["variations"] as? [String: Any])
        var plural = try #require(variations["plural"] as? [String: Any])
        plural.removeValue(forKey: "one")
        variations["plural"] = plural
        mutated["variations"] = variations
        localizations[language] = mutated
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.missingVariationPath(
                key: "feature.count.format",
                language: language,
                path: "variations.plural.one"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v141Identifiers
            )
        }
    }

    @Test func completeCatalogRejectsMissingKoreanPluralOther() throws {
        var localizations = version141PluralFixtureLocalizations()
        localizations["ko"] = fixturePluralLocalization(
            one: "%lld개 항목",
            other: "%lld개 항목"
        )
        var korean = try #require(localizations["ko"] as? [String: Any])
        var variations = try #require(korean["variations"] as? [String: Any])
        var plural = try #require(variations["plural"] as? [String: Any])
        plural.removeValue(forKey: "other")
        variations["plural"] = plural
        korean["variations"] = variations
        localizations["ko"] = korean
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.missingVariationPath(
                key: "feature.count.format",
                language: "ko",
                path: "variations.plural.other"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v141Identifiers
            )
        }
    }

    @Test func completeCatalogRejectsRedundantKoreanPluralOne() throws {
        var localizations = version141PluralFixtureLocalizations()
        localizations["ko"] = fixturePluralLocalization(
            one: "%lld개 항목",
            other: "%lld개 항목"
        )
        let catalog = try makeCatalogFixture(localizations: localizations)

        #expect(
            throws: StringCatalogContractError.unexpectedVariationPath(
                key: "feature.count.format",
                language: "ko",
                path: "variations.plural.one"
            )
        ) {
            try assertCompleteCatalog(
                at: catalog,
                requiredLanguages: SupportedLocalization.v141Identifiers
            )
        }
    }

    private func completeFixtureLocalizations() -> [String: Any] {
        [
            "en": fixtureLocalization(value: "%lld items"),
            "zh-Hant": fixtureLocalization(value: "%lld 項"),
            "zh-Hans": fixtureLocalization(value: "%lld 项"),
            "de": fixtureLocalization(value: "%lld Elemente"),
            "fr": fixtureLocalization(value: "%lld articles"),
            "ja": fixtureLocalization(value: "%lld 件"),
        ]
    }

    private func version141PluralFixtureLocalizations() -> [String: Any] {
        let oneAndOther = fixturePluralLocalization(
            one: "%lld item",
            other: "%lld items"
        )
        let otherOnly = fixtureOtherOnlyPluralLocalization(other: "%lld items")
        return [
            "en": oneAndOther,
            "zh-Hant": otherOnly,
            "zh-Hans": otherOnly,
            "de": oneAndOther,
            "fr": oneAndOther,
            "ja": otherOnly,
            "nb": oneAndOther,
            "sv": oneAndOther,
            "fi": oneAndOther,
            "da": oneAndOther,
            "ko": otherOnly,
            "el": oneAndOther,
        ]
    }

    private func fixtureLocalization(
        value: String,
        state: String = "translated"
    ) -> [String: Any] {
        ["stringUnit": ["state": state, "value": value]]
    }

    private func fixturePluralLocalization(
        one: String,
        other: String
    ) -> [String: Any] {
        [
            "variations": [
                "plural": [
                    "one": fixtureLocalization(value: one),
                    "other": fixtureLocalization(value: other),
                ],
            ],
        ]
    }

    private func fixtureOtherOnlyPluralLocalization(other: String) -> [String: Any] {
        [
            "variations": [
                "plural": [
                    "other": fixtureLocalization(value: other),
                ],
            ],
        ]
    }

    private func oracleEntry(
        effectiveEnglish: String,
        sourceMetadata: [String: Any] = ["comment": "Fixture source intent"]
    ) -> [String: Any] {
        [
            "sourceMetadata": sourceMetadata,
            "effectiveEnglish": [
                [
                    "path": [],
                    "state": "translated",
                    "value": effectiveEnglish,
                ],
            ],
        ]
    }

    private func makeCatalogOracleFixture(
        entries: [String: Any]? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "StringCatalogOracle-\(UUID().uuidString).json")
        let oracle: [String: Any] = [
            "sourceCommit": "f0116e0",
            "catalogs": [
                "fixture": [
                    "rootMetadata": [
                        "sourceLanguage": "en",
                        "version": "1.0",
                    ],
                    "entries": entries ?? [
                        "feature.count.format": oracleEntry(effectiveEnglish: "%lld items"),
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: oracle).write(to: url, options: .atomic)
        return url
    }

    private func makeCatalogFixture(
        localizations: [String: Any]? = nil,
        entryMetadata: [String: Any] = ["comment": "Fixture source intent"]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "StringCatalogContract-\(UUID().uuidString).xcstrings")
        var entry = entryMetadata
        entry["localizations"] = localizations ?? completeFixtureLocalizations()
        let catalog: [String: Any] = [
            "sourceLanguage": "en",
            "strings": [
                "feature.count.format": entry,
            ],
            "version": "1.0",
        ]
        try JSONSerialization.data(withJSONObject: catalog).write(to: url, options: .atomic)
        return url
    }
}

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
        "yarn.error.completedProjectLink",
        "yarn.error.loadFailed.title",
        "yarn.error.loadFailed.message",
        "project.yarn.choose",
        "project.yarn.completed.readOnly",
        "project.yarn.error.projectUnavailable",
        "project.yarn.error.saveRetry",
        "project.yarn.error.yarnUnavailable",
        "project.yarn.empty",
        "project.yarn.libraryEmpty.message",
        "project.yarn.libraryEmpty.title",
        "project.yarn.manage",
        "project.yarn.title",
        "project.yarn.unlink.action",
        "project.yarn.unlink.message",
        "project.yarn.unlink.title",
        "project.yarn.toggle.hint",
        "yarn.addManually",
        "yarn.addManually.hint",
        "yarn.ballWeightGrams",
        "yarn.fiberContent",
        "yarn.label.details",
        "yarn.labelPhoto.accessibility %lld",
        "yarn.labelPhoto.remove",
        "yarn.labelPhotos",
        "yarn.labelPhotos.storage.unavailable",
        "yarn.range.lower",
        "yarn.range.upper",
        "yarn.recommendedHookMM",
        "yarn.recommendedNeedleMM",
        "yarn.scan.action",
        "yarn.scan.action.hint",
        "yarn.scan.camera",
        "yarn.scan.camera.denied",
        "yarn.scan.failed",
        "yarn.scan.finder",
        "yarn.scan.image.error",
        "yarn.scan.image.remove",
        "yarn.scan.image.remove.hint",
        "yarn.scan.images.empty",
        "yarn.scan.images.hint",
        "yarn.scan.leaveBlank",
        "yarn.scan.needsConfirmation",
        "yarn.scan.openSettings",
        "yarn.scan.photoLibrary",
        "yarn.scan.recognize",
        "yarn.scan.recognizing",
        "yarn.scan.review.hint",
        "yarn.scan.review.message",
        "yarn.scan.review.title",
        "yarn.scan.title",
        "yarn.section.basic",
        "yarn.section.inventory",
        "yarn.section.storage",
    ]

    private let requiredYarnSectionTranslations = [
        "yarn.section.basic": ["en": "Basic Details", "zh-Hant": "基本資料"],
        "yarn.section.inventory": ["en": "Inventory", "zh-Hant": "庫存"],
        "yarn.section.storage": ["en": "Storage & Notes", "zh-Hant": "收納與筆記"],
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

    private let requiredReaderTranslations = [
        "counter.accessibility.readOnlyHint": [
            "en": "Counter is read-only.",
            "zh-Hant": "計數器僅供查看。",
        ],
        "patterns.reader.thumbnail.accessibility.format": [
            "en": "Page %1$lld of %2$lld",
            "zh-Hant": "第 %1$lld 頁，共 %2$lld 頁",
        ],
        "patterns.reader.thumbnail.current": [
            "en": "Current page",
            "zh-Hant": "目前頁",
        ],
        "patterns.reader.conflict": [
            "en": "Pattern changed elsewhere",
            "zh-Hant": "織圖已在其他位置變更",
        ],
        "patterns.reader.thumbnail.hint": [
            "en": "Double-tap to open this page.",
            "zh-Hant": "點兩下即可前往這一頁。",
        ],
    ]

    private let requiredPatternAppearanceTranslations = [
        "patterns.appearance.showOriginal": [
            "en": "Show Original Colors",
            "zh-Hant": "顯示原色",
        ],
        "patterns.appearance.useNight": [
            "en": "Use Night Appearance",
            "zh-Hant": "使用夜間顯示",
        ],
        "patterns.appearance.darkHint": [
            "en": "Changes this pattern only.",
            "zh-Hant": "只變更這份織圖。",
        ],
        "patterns.appearance.lightHint": [
            "en": "This choice is used automatically in Dark Mode.",
            "zh-Hant": "此選擇會在深色模式中自動套用。",
        ],
    ]

    private let requiredYouTubeTranslations = [
        "common.add": ["en": "Add", "zh-Hant": "新增"],
        "patterns.youtube.add": ["en": "Add YouTube Link", "zh-Hant": "加入 YouTube 連結"],
        "patterns.youtube.url": ["en": "YouTube URL", "zh-Hant": "YouTube 網址"],
        "patterns.youtube.readMetadata": ["en": "Read Video Info", "zh-Hant": "讀取影片資料"],
        "patterns.youtube.loading": ["en": "Reading video info…", "zh-Hant": "讀取影片資料中…"],
        "patterns.youtube.title": ["en": "Title", "zh-Hant": "標題"],
        "patterns.youtube.type": ["en": "YouTube Video", "zh-Hant": "YouTube 影片"],
        "patterns.youtube.open": ["en": "Open in YouTube", "zh-Hant": "在 YouTube 開啟"],
        "patterns.youtube.status": ["en": "Video info status", "zh-Hant": "影片資料狀態"],
        "patterns.youtube.fallback.manualTitle": [
            "en": "Video info couldn't be loaded. Enter a title to save this link.",
            "zh-Hant": "無法讀取影片資料。輸入標題後仍可儲存連結。",
        ],
        "patterns.youtube.error.invalidURL": [
            "en": "Enter a valid YouTube link.",
            "zh-Hant": "請輸入有效的 YouTube 連結。",
        ],
        "patterns.youtube.error.metadata": [
            "en": "Video info couldn't be loaded. Enter a title to save this link.",
            "zh-Hant": "無法讀取影片資料。輸入標題後仍可儲存連結。",
        ],
        "patterns.youtube.error.open": [
            "en": "Couldn't open YouTube. Please try again.",
            "zh-Hant": "無法開啟 YouTube，請再試一次。",
        ],
        "patterns.youtube.accessibility.thumbnail": [
            "en": "YouTube video thumbnail",
            "zh-Hant": "YouTube 影片縮圖",
        ],
        "patterns.youtube.link": ["en": "YouTube Link", "zh-Hant": "YouTube 連結"],
        "patterns.youtube.details": ["en": "Video Details", "zh-Hant": "影片資料"],
        "patterns.youtube.invalidLink": [
            "en": "Enter a valid YouTube link.",
            "zh-Hant": "請輸入有效的 YouTube 連結。",
        ],
        "patterns.youtube.metadataUnavailable": [
            "en": "Video info couldn't be loaded. Enter a title to save this link.",
            "zh-Hant": "無法讀取影片資料。輸入標題後仍可儲存連結。",
        ],
        "patterns.youtube.addFailed": [
            "en": "Couldn't save the YouTube link. Please try again.",
            "zh-Hant": "無法儲存 YouTube 連結，請再試一次。",
        ],
    ]

    private let requiredPatternCalculatorTranslations = [
        "patterns.calculator.title": ["en": "Calculator", "zh-Hant": "計算機"],
        "patterns.calculator.hint": ["en": "Opens a calculator without leaving the pattern", "zh-Hant": "不離開織圖即可開啟計算機"],
        "patterns.calculator.clear": ["en": "All Clear", "zh-Hant": "全部清除"],
        "patterns.calculator.result": ["en": "Result", "zh-Hant": "結果"],
        "patterns.calculator.error": ["en": "Error", "zh-Hant": "錯誤"],
        "patterns.calculator.add": ["en": "Add", "zh-Hant": "加"],
        "patterns.calculator.subtract": ["en": "Subtract", "zh-Hant": "減"],
        "patterns.calculator.multiply": ["en": "Multiply", "zh-Hant": "乘"],
        "patterns.calculator.divide": ["en": "Divide", "zh-Hant": "除"],
        "patterns.calculator.equals": ["en": "Equals", "zh-Hant": "等於"],
        "patterns.calculator.percent": ["en": "Percent", "zh-Hant": "百分比"],
        "patterns.calculator.toggleSign": ["en": "Change Sign", "zh-Hant": "切換正負號"],
    ]

    private let requiredSettingsAboutTranslations = [
        "settings.general": ["en": "General", "zh-Hant": "一般"],
        "settings.data": ["en": "Data", "zh-Hant": "資料"],
        "settings.about": ["en": "About", "zh-Hant": "關於"],
        "settings.version": ["en": "Version", "zh-Hant": "版本"],
        "settings.version.format": ["en": "%1$@ (Build %2$@)", "zh-Hant": "%1$@（Build %2$@）"],
    ]

    private let task13PatternPrefixes = [
        "patterns.library.",
        "patterns.detail.",
        "patterns.import.",
        "patterns.link.",
        "patterns.unlink.",
        "patterns.share.",
        "patterns.backup.",
        "patterns.inbox.",
        "patterns.reader.chooseContext.",
        "backup.lastSuccessful.",
    ]

    private let task13StandalonePatternKeys: Set<String> = [
        "patterns.importNew",
        "patterns.linkExisting",
        "patterns.relink",
        "patterns.unlink",
        "patterns.reader.readOnly",
        "patterns.library.row.accessibility.format",
    ]

    private let requiredPatternLibraryTranslations = [
        "patterns.library.empty.title": ["en": "No Patterns Yet", "zh-Hant": "還沒有織圖"],
        "patterns.library.empty.message": ["en": "Add your first PDF or image pattern.", "zh-Hant": "加入第一份 PDF 或圖片織圖吧。"],
        "patterns.library.search": ["en": "Search patterns", "zh-Hant": "搜尋織圖"],
        "patterns.library.sort": ["en": "Sort patterns", "zh-Hant": "織圖排序"],
        "patterns.library.sort.recent": ["en": "Recently Added", "zh-Hant": "最近加入"],
        "patterns.library.sort.name": ["en": "Name", "zh-Hant": "名稱"],
        "patterns.library.unused": ["en": "Not used yet", "zh-Hant": "尚未使用"],
        "patterns.library.links.format": ["en": "%lld linked projects", "zh-Hant": "已連結 %lld 件作品"],
        "patterns.library.pdf.pages.format": ["en": "PDF, %lld pages", "zh-Hant": "PDF，共 %lld 頁"],
        "patterns.library.pdf": ["en": "PDF", "zh-Hant": "PDF"],
        "patterns.library.image": ["en": "Image", "zh-Hant": "圖片"],
        "patterns.library.thumbnail": ["en": "Pattern preview", "zh-Hant": "織圖預覽"],
        "patterns.library.alreadySaved.title": ["en": "Already Saved", "zh-Hant": "已收藏"],
        "patterns.library.alreadySaved.message": ["en": "This pattern is already in your library.", "zh-Hant": "這份織圖已收藏在織圖匣中。"],
        "patterns.library.alreadySaved.view": ["en": "View Saved Pattern", "zh-Hant": "查看已收藏織圖"],
        "patterns.linkExisting": ["en": "Link from Pattern Library", "zh-Hant": "從織圖匣連結"],
        "patterns.importNew": ["en": "Import New Pattern", "zh-Hant": "匯入新織圖"],
        "patterns.relink": ["en": "Relink", "zh-Hant": "重新連結"],
        "patterns.unlink": ["en": "Unlink", "zh-Hant": "解除連結"],
        "patterns.unlink.confirm.title": ["en": "Unlink this pattern?", "zh-Hant": "解除這份織圖的作品連結？"],
        "patterns.unlink.confirm.message": ["en": "The pattern stays in your library, and this project's saved reading data is kept.", "zh-Hant": "織圖會保留在織圖匣中，這件作品已儲存的閱讀資料也會保留。"],
        "patterns.link.choose": ["en": "Choose a Pattern", "zh-Hant": "選擇織圖"],
        "patterns.link.empty": ["en": "All library patterns are already linked.", "zh-Hant": "織圖匣中的織圖都已連結。"],
        "patterns.import.files": ["en": "Choose File", "zh-Hant": "從檔案選擇"],
        "patterns.import.camera": ["en": "Camera", "zh-Hant": "相機"],
        "patterns.import.cameraName": ["en": "Camera Pattern", "zh-Hant": "相機織圖"],
        "patterns.import.processing": ["en": "Importing Pattern", "zh-Hant": "正在匯入織圖"],
        "patterns.import.success.title": ["en": "Pattern Linked", "zh-Hant": "織圖已連結"],
        "patterns.import.success.created": ["en": "The pattern was saved and linked to this project.", "zh-Hant": "織圖已收藏並連結到這件作品。"],
        "patterns.import.success.existing": ["en": "The saved pattern was linked to this project.", "zh-Hant": "已收藏的織圖已連結到這件作品。"],
        "patterns.import.chooseDuplicate": ["en": "Choose the Saved Pattern", "zh-Hant": "選擇已收藏的織圖"],
        "patterns.import.error.empty": ["en": "This file is empty.", "zh-Hant": "這個檔案是空的。"],
        "patterns.import.error.tooLarge": ["en": "This file is too large to import.", "zh-Hant": "這個檔案太大，無法匯入。"],
        "patterns.import.error.invalidFile": ["en": "Choose a valid PDF or image file.", "zh-Hant": "請選擇有效的 PDF 或圖片檔案。"],
        "patterns.import.error.storage": ["en": "The pattern could not be saved. Please try again.", "zh-Hant": "無法儲存織圖，請再試一次。"],
        "patterns.import.error.projectUnavailable": ["en": "This project is no longer available.", "zh-Hant": "這件作品已不存在。"],
        "patterns.import.error.cancelled": ["en": "The import was cancelled.", "zh-Hant": "匯入已取消。"],
        "patterns.import.error.fileSelection": ["en": "The selected file could not be opened.", "zh-Hant": "無法開啟所選檔案。"],
        "patterns.import.error.unexpected": ["en": "The pattern could not be imported. Please try again.", "zh-Hant": "無法匯入織圖，請再試一次。"],
        "patterns.detail.information": ["en": "File Information", "zh-Hant": "檔案資訊"],
        "patterns.detail.fileType": ["en": "File type", "zh-Hant": "檔案類型"],
        "patterns.detail.fileSize": ["en": "File size", "zh-Hant": "檔案大小"],
        "patterns.detail.added": ["en": "Added", "zh-Hant": "加入日期"],
        "patterns.detail.note": ["en": "Note", "zh-Hant": "備註"],
        "patterns.detail.note.empty": ["en": "Add a designer, shop, or source note.", "zh-Hant": "可記下設計師、商店或來源。"],
        "patterns.detail.linkedProjects": ["en": "Linked Projects", "zh-Hant": "已連結作品"],
        "patterns.detail.linkProject": ["en": "Link Another Project", "zh-Hant": "連結其他作品"],
        "patterns.detail.export": ["en": "Share Original File", "zh-Hant": "分享原始檔"],
        "patterns.detail.open": ["en": "Open Pattern", "zh-Hant": "開啟織圖"],
        "patterns.detail.rename": ["en": "Rename Pattern", "zh-Hant": "重新命名織圖"],
        "patterns.detail.editNote": ["en": "Edit Note", "zh-Hant": "編輯備註"],
        "patterns.detail.unlink": ["en": "Unlink", "zh-Hant": "解除連結"],
        "patterns.detail.delete": ["en": "Permanently Delete Pattern", "zh-Hant": "永久刪除織圖"],
        "patterns.detail.deleteBlocked": ["en": "Unlink this pattern from the projects below before deleting it.", "zh-Hant": "請先解除下列作品連結，才能永久刪除織圖。"],
        "patterns.detail.delete.confirm.title": ["en": "Permanently delete this pattern?", "zh-Hant": "永久刪除這份織圖？"],
        "patterns.detail.delete.confirm.message": ["en": "The original file and saved reading data will be deleted. This cannot be undone.", "zh-Hant": "原始檔與保留的閱讀資料都會刪除，且無法復原。"],
        "patterns.detail.chooseProject": ["en": "Choose a Project", "zh-Hant": "選擇作品"],
        "patterns.detail.noProjects": ["en": "No other projects are available.", "zh-Hant": "沒有其他可連結的作品。"],
        "patterns.reader.chooseContext.title": ["en": "Choose Reading Context", "zh-Hant": "選擇閱讀作品"],
        "patterns.reader.chooseContext.message": ["en": "Choose which project's reading progress to continue.", "zh-Hant": "請選擇要繼續哪件作品的閱讀進度。"],
        "patterns.reader.readOnly": ["en": "Read Only", "zh-Hant": "只閱讀"],
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

    @Test func mainAppCatalogIsCompleteForVersion141Languages() throws {
        try assertCatalogMatchesOracle(
            at: repositoryRoot.appending(
                path: "KnitNote/Localization/Localizable.xcstrings"
            ),
            oracleAt: repositoryRoot.appending(
                path: "Tests/KnitNoteCoreTests/Fixtures/KnitNote-1.4.0-CatalogOracle.json"
            ),
            catalogName: "main",
            expectedSourceCommit: "f0116e0",
            permittedAdditionalKeys: [
                "language.norwegianBokmal",
                "language.swedish",
                "language.finnish",
                "language.danish",
                "language.korean",
                "language.greek",
            ]
        )
        try assertCompleteCatalog(
            at: repositoryRoot.appending(
                path: "KnitNote/Localization/Localizable.xcstrings"
            ),
            requiredLanguages: SupportedLocalization.v141Identifiers
        )
    }

    @Test func infoPlistCatalogIsCompleteForVersion141Languages() throws {
        try assertCatalogMatchesOracle(
            at: repositoryRoot.appending(
                path: "KnitNote/Localization/InfoPlist.xcstrings"
            ),
            oracleAt: repositoryRoot.appending(
                path: "Tests/KnitNoteCoreTests/Fixtures/KnitNote-1.4.0-CatalogOracle.json"
            ),
            catalogName: "infoPlist",
            expectedSourceCommit: "f0116e0"
        )
        try assertCompleteCatalog(
            at: repositoryRoot.appending(
                path: "KnitNote/Localization/InfoPlist.xcstrings"
            ),
            requiredLanguages: SupportedLocalization.v141Identifiers
        )
    }

    @Test func version141LanguagePickerKeysExistAndAreCompleteInEveryLanguage() throws {
        let strings = try catalogStrings()
        let expectedEnglish = [
            "language.norwegianBokmal": "Norwegian Bokmål",
            "language.swedish": "Swedish",
            "language.finnish": "Finnish",
            "language.danish": "Danish",
            "language.korean": "Korean",
            "language.greek": "Greek",
        ]

        for (key, english) in expectedEnglish {
            #expect(try localizedValue(key, language: "en", strings: strings) == english)
            for language in SupportedLocalization.v141Identifiers {
                let value = try localizedValue(key, language: language, strings: strings)
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @Test func version141CommonActionsUseApprovedConcisePlatformCopy() throws {
        let strings = try catalogStrings()
        let actionGroups: [([String], [String: String])] = [
            (["backup.alert.dismiss", "common.ok"], [
                "nb": "OK", "sv": "OK", "fi": "OK", "da": "OK", "ko": "확인", "el": "OK",
            ]),
            (["backup.cancel", "common.cancel"], [
                "nb": "Avbryt", "sv": "Avbryt", "fi": "Peruuta", "da": "Annuller", "ko": "취소", "el": "Ακύρωση",
            ]),
            (["common.add", "patterns.calculator.add"], [
                "nb": "Legg til", "sv": "Lägg till", "fi": "Lisää", "da": "Tilføj", "ko": "추가", "el": "Προσθήκη",
            ]),
            (["common.delete", "journal.delete"], [
                "nb": "Slett", "sv": "Radera", "fi": "Poista", "da": "Slet", "ko": "삭제", "el": "Διαγραφή",
            ]),
            (["common.save"], [
                "nb": "Lagre", "sv": "Spara", "fi": "Tallenna", "da": "Gem", "ko": "저장", "el": "Αποθήκευση",
            ]),
            (["common.retry"], [
                "nb": "Prøv igjen", "sv": "Försök igen", "fi": "Yritä uudelleen", "da": "Prøv igen", "ko": "다시 시도", "el": "Δοκιμάστε ξανά",
            ]),
            (["patterns.markup.undo", "project.undo"], [
                "nb": "Angre", "sv": "Ångra", "fi": "Kumoa", "da": "Fortryd", "ko": "실행 취소", "el": "Αναίρεση",
            ]),
            (["patterns.detail.unlink", "patterns.unlink", "project.yarn.unlink.action"], [
                "nb": "Fjern kobling", "sv": "Ta bort länk", "fi": "Poista linkitys", "da": "Fjern link", "ko": "연결 해제", "el": "Αποσύνδεση",
            ]),
            (["project.rename"], [
                "nb": "Gi nytt navn", "sv": "Byt namn", "fi": "Nimeä uudelleen", "da": "Omdøb", "ko": "이름 변경", "el": "Μετονομασία",
            ]),
            (["patterns.backup.reminder.dismiss"], [
                "nb": "Ikke nå", "sv": "Inte nu", "fi": "Ei nyt", "da": "Ikke nu", "ko": "나중에", "el": "Όχι τώρα",
            ]),
            (["yarn.scan.recognize"], [
                "nb": "Gjenkjenn", "sv": "Identifiera", "fi": "Tunnista", "da": "Genkend", "ko": "인식", "el": "Αναγνώριση",
            ]),
        ]

        for (keys, expectedTranslations) in actionGroups {
            for key in keys {
                for (language, expectedValue) in expectedTranslations {
                    #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
                }
            }
        }
    }

    @Test func version141CriticalWorkflowCopyUsesApprovedProductLanguage() throws {
        let strings = try catalogStrings()
        let expected: [String: [String: String]] = [
            "backup.preparing": ["fi": "Valmistellaan varmuuskopiota…"],
            "backup.error.storageOrAccess": [
                "fi": "KnitNote ei voinut käyttää varmuuskopiota tai tallennustila ei riitä.",
            ],
            "unlock.trial.active.one": [
                "fi": "Kokeilujaksoa jäljellä 1 päivä",
                "el": "Απομένει 1 ημέρα δοκιμής",
            ],
            "unlock.trial.active.many.format": [
                "fi": "Kokeilujaksoa jäljellä %lld päivää",
                "el": "Απομένουν %lld ημέρες δοκιμής",
            ],
            "yarn.range.lower": ["fi": "Alkaen"],
            "yarn.range.upper": ["fi": "Saakka"],
            "calculator.adjustment.edgeSummary": [
                "el": "Ένας πόντος ακμής διατηρείται σε κάθε πλευρά.",
            ],
            "calculator.adjustment.failure.invalidCounts": [
                "el": "Εισαγάγετε έγκυρο τρέχοντα και επιθυμητό αριθμό πόντων.",
            ],
            "counter.accessibility.rename": [
                "ko": "%@ 이름 변경, 현재 값 %lld",
            ],
        ]

        for (key, expectedTranslations) in expected {
            for (language, expectedValue) in expectedTranslations {
                #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
            }
        }
    }

    @Test func counterStringsHaveEveryVersion140Translation() throws {
        let strings = try catalogStrings()

        for key in requiredKeys {
            let localizations = try #require(strings[key] as? [String: Any])
            let translations = try #require(localizations["localizations"] as? [String: Any])
            for language in SupportedLocalization.v140Identifiers {
                let translation = try #require(translations[language] as? [String: Any])
                let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
                #expect(!(try #require(stringUnit["value"] as? String)).isEmpty)
            }
        }
    }

    @Test func yarnEditorSectionTitlesUseApprovedBilingualCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedTranslations) in requiredYarnSectionTranslations {
            for (language, expectedValue) in expectedTranslations {
                #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
            }
        }
    }

    @Test func readerConflictAndReadOnlyHintsUseTheApprovedBilingualCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedTranslations) in requiredReaderTranslations {
            for (language, expectedValue) in expectedTranslations {
                #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
            }
        }
    }

    @Test func patternAppearanceControlsUseTheApprovedManualBilingualCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedTranslations) in requiredPatternAppearanceTranslations {
            let entry = try #require(strings[key] as? [String: Any])
            #expect(entry["extractionState"] as? String == "manual")
            for (language, expectedValue) in expectedTranslations {
                #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
            }
        }
    }

    @Test func youtubePatternLinksHaveExactEnglishAndTraditionalChineseCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedTranslations) in requiredYouTubeTranslations {
            for (language, expectedValue) in expectedTranslations {
                let value = try localizedValue(key, language: language, strings: strings)
                #expect(value == expectedValue)
                #expect(value != key)
            }
        }
    }

    @Test func patternCalculatorUsesApprovedEnglishAndTraditionalChineseCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedTranslations) in requiredPatternCalculatorTranslations {
            for (language, expectedValue) in expectedTranslations {
                #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
            }
        }
    }

    @Test func settingsAboutUsesApprovedEnglishAndTraditionalChineseCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedTranslations) in requiredSettingsAboutTranslations {
            for (language, expectedValue) in expectedTranslations {
                #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
            }
        }
    }

    @Test func patternLibraryStringsHaveApprovedEnglishAndTraditionalChineseCopy() throws {
        let strings = try catalogStrings()

        for (key, expectedTranslations) in requiredPatternLibraryTranslations {
            for (language, expectedValue) in expectedTranslations {
                #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
            }
        }
    }

    @Test func linkedProjectCountUsesNaturalCopyForOneAndMany() throws {
        let strings = try catalogStrings()
        let cases = [
            (count: 1, english: "1 linked project", traditionalChinese: "已連結 1 件作品"),
            (count: 2, english: "2 linked projects", traditionalChinese: "已連結 2 件作品"),
        ]

        for testCase in cases {
            #expect(
                try pluralizedValue(
                    "patterns.library.links.format",
                    language: "en",
                    count: testCase.count,
                    strings: strings
                ) == testCase.english
            )
            #expect(
                try pluralizedValue(
                    "patterns.library.links.format",
                    language: "zh-Hant",
                    count: testCase.count,
                    strings: strings
                ) == testCase.traditionalChinese
            )
        }
    }

    @Test func task7Through12VisiblePatternKeysAreCompleteAndNonempty() throws {
        let strings = try catalogStrings()
        let catalogKeys = Set(strings.keys.filter(isTask13PatternKey))
        let sourceKeys = try task13PatternSourceKeys()
        let requiredKeys = catalogKeys
            .union(sourceKeys.filter(isTask13PatternKey))
            .union(task13StandalonePatternKeys)

        #expect(!requiredKeys.isEmpty)
        for key in requiredKeys.sorted() {
            for language in SupportedLocalization.v140Identifiers {
                let value = try localizedValue(key, language: language, strings: strings)
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @Test func patternRowAccessibilityFormatNamesAllThreeVisibleFacts() throws {
        let strings = try catalogStrings()

        for language in SupportedLocalization.v140Identifiers {
            let value = try localizedValue(
                "patterns.library.row.accessibility.format",
                language: language,
                strings: strings
            )
            for placeholder in ["%1$@", "%2$@", "%3$@"] {
                #expect(value.components(separatedBy: placeholder).count == 2)
            }
        }
    }

    @Test func shareExtensionVisibleKeysAreBilingualAndNonempty() throws {
        let strings = try shareCatalogStrings()
        let sourceKeys = try localizationKeys(
            in: [
                "KnitNoteShare/ShareImportView.swift",
                "KnitNoteShare/ShareViewController.swift",
            ],
            matching: #"share\.[A-Za-z0-9._-]+"#
        )
        let requiredKeys = Set(strings.keys.filter { $0.hasPrefix("share.") })
            .union(sourceKeys)

        #expect(!requiredKeys.isEmpty)
        for key in requiredKeys.sorted() {
            for language in ["en", "zh-Hant"] {
                let value = try localizedValue(key, language: language, strings: strings)
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    @Test func yarnStringsHaveEveryVersion140Translation() throws {
        let strings = try catalogStrings()

        for key in requiredYarnKeys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in SupportedLocalization.v140Identifiers {
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

    @Test func cameraPurposeDescriptionMentionsProjectsJournalEntriesAndYarnLabels() throws {
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
                == "Take photos for knitting projects, journal entries, and yarn labels."
        )
        #expect(
            try infoPlistLocalizedValue("zh-Hant", localizations: localizations)
                == "拍攝照片加入你的編織作品、編織日記與毛線標籤。"
        )
    }

    @Test func journalCardAccessibilityFormatsKeepTheirExactPlaceholderContracts() throws {
        let strings = try catalogStrings()

        for language in SupportedLocalization.v140Identifiers {
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

    @Test func gaugeCalculatorStringsHaveEveryVersion140Translation() throws {
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
            for language in SupportedLocalization.v140Identifiers {
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

        for language in SupportedLocalization.v140Identifiers {
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
            let limitCopy = try localizedValue(
                "calculator.adjustment.failure.exceedsSupportedLimit.format",
                language: language,
                strings: strings
            )
            #expect(limitCopy.replacingOccurrences(
                of: #"[\s,.]"#,
                with: "",
                options: .regularExpression
            ).contains("100000"))
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

        for language in SupportedLocalization.v140Identifiers {
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
            let limitCopy = try localizedValue(
                "calculator.adjustment.rows.failure.exceedsSupportedLimit.format",
                language: language,
                strings: strings
            )
            #expect(limitCopy.replacingOccurrences(
                of: #"[\s,.]"#,
                with: "",
                options: .regularExpression
            ).contains("100000"))
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

        for language in SupportedLocalization.v140Identifiers {
            let translation = try #require(localizations[language] as? [String: Any])
            let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
            let value = try #require(stringUnit["value"] as? String)
            #expect(value.components(separatedBy: "%@").count == 4)
        }
    }

    @Test func defaultCounterNameFormatsAnOrdinalInEveryVersion140Language() throws {
        let strings = try catalogStrings()
        let entry = try #require(strings["counter.defaultName"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])

        for language in SupportedLocalization.v140Identifiers {
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
            for language in SupportedLocalization.v140Identifiers {
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
        #expect(source.contains("LocaleAwareText.format("))
        #expect(source.contains("\"counter.defaultName\""))
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
        #expect(values.filter { $0.contains("樣式庫") }.isEmpty)
        #expect(try localizedValue("patterns.title", language: "zh-Hant", strings: strings) == "織圖")
        #expect(try localizedValue("patterns.open", language: "zh-Hant", strings: strings) == "織圖")
        #expect(try localizedValue("patterns.add", language: "zh-Hant", strings: strings) == "加入織圖")
    }

    @Test func simplifiedChineseUsesReviewedMainlandProductAndAccessibilityCopy() throws {
        let strings = try catalogStrings()
        let exactCopy = [
            "backup.replace.warning": "恢复后将替换当前所有 KnitNote 数据。",
            "backup.restore.confirm": "替换并恢复",
            "counter.accessibility.collapse": "折叠 %@ 的计数器控件，当前值 %lld",
            "counter.accessibility.decrement": "减少 %@，当前值 %lld",
            "counter.accessibility.expand": "展开 %@ 的计数器控件，当前值 %lld",
            "counter.accessibility.increment": "增加 %@，当前值 %lld",
            "counter.accessibility.note": "编辑 %@ 的笔记，当前值 %lld",
            "patterns.reader.readOnly": "只读",
            "patterns.youtube.accessibility.thumbnail": "YouTube 视频缩略图",
            "patterns.youtube.details": "视频信息",
            "patterns.youtube.loading": "正在读取视频信息…",
            "patterns.youtube.readMetadata": "读取视频信息",
            "patterns.youtube.status": "视频信息状态",
            "patterns.youtube.type": "YouTube 视频",
            "settings.general": "通用",
        ]

        for (key, expectedValue) in exactCopy {
            #expect(try localizedValue(key, language: "zh-Hans", strings: strings) == expectedValue)
        }

        let forbiddenTerms = [
            "取代", "目前", "收合", "只阅读", "影片", "套用", "选填", "取得",
            "这则", "这部设备", "建立", "加入", "仅供查看", "一至两张",
        ]
        let values = localizedValues(language: "zh-Hans", strings: strings)
        let forbiddenHits = forbiddenTerms.flatMap { term in
            values.filter { $0.contains(term) }.map { "\(term): \($0)" }
        }
        #expect(forbiddenHits.isEmpty)
    }

    @Test func frenchDestructiveAndSafetyCopyStatesTheActualOutcome() throws {
        let strings = try catalogStrings()
        let exactCopy = [
            "patterns.inbox.discard": "Supprimer le fichier",
            "patterns.inbox.error.message": "KnitNote n’a pas pu enregistrer le patron partagé. Réessayez ou supprimez ce fichier.",
            "project.yarn.completed.readOnly": "Les associations de fils des projets terminés sont en lecture seule.",
            "backup.error.unsupportedVersion": "Cette sauvegarde a été créée avec une version plus récente de KnitNote. Mettez l’app à jour avant de restaurer cette sauvegarde.",
        ]

        for (key, expectedValue) in exactCopy {
            #expect(try localizedValue(key, language: "fr", strings: strings) == expectedValue)
        }
    }

    @Test func reviewedGermanJapaneseStorageAndLifetimeCopyKeepsDistinctMeaning() throws {
        let strings = try catalogStrings()
        let exactCopy: [String: [String: String]] = [
            "patterns.highlight": ["de": "Markierung"],
            "patterns.highlightMode": ["de": "Markierungsmodus"],
            "patterns.highlight.horizontalControl": ["de": "Horizontale Markierung"],
            "patterns.highlight.verticalControl": ["de": "Vertikale Markierung"],
            "patterns.markup": ["de": "Zeichnen"],
            "patterns.markup.clear": ["de": "Zeichnungen löschen"],
            "patterns.markup.clear.confirm": ["de": "Alle Zeichnungen auf dieser Seite löschen?"],
            "patterns.import.cameraName": ["ja": "カメラで撮影した編み図"],
            "yarn.storageLocation": [
                "de": "Aufbewahrungsort",
                "fr": "Lieu de rangement",
            ],
            "unlock.lifetime.message": [
                "fr": "Un seul achat déverrouille KnitNote à vie.",
                "ja": "1回の購入でKnitNoteを永久にアンロックできます。",
            ],
        ]

        for (key, translations) in exactCopy {
            for (language, expectedValue) in translations {
                #expect(try localizedValue(key, language: language, strings: strings) == expectedValue)
            }
        }
    }

    private func catalogStrings() throws -> [String: Any] {
        let root = repositoryRoot
        let catalogURL = root.appending(path: "KnitNote/Localization/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(catalog["strings"] as? [String: Any])
    }

    private func localizedValues(
        language: String,
        strings: [String: Any]
    ) -> [String] {
        strings.values.flatMap { entry -> [String] in
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let localization = localizations[language]
            else { return [] }
            return stringUnitValues(in: localization)
        }
    }

    private func stringUnitValues(in node: Any) -> [String] {
        if let dictionary = node as? [String: Any] {
            var values: [String] = []
            if let stringUnit = dictionary["stringUnit"] as? [String: Any],
               let value = stringUnit["value"] as? String {
                values.append(value)
            }
            for key in dictionary.keys where key != "stringUnit" {
                if let child = dictionary[key] {
                    values.append(contentsOf: stringUnitValues(in: child))
                }
            }
            return values
        }
        if let array = node as? [Any] {
            return array.flatMap(stringUnitValues(in:))
        }
        return []
    }

    private func watchCatalogStrings() throws -> [String: Any] {
        let catalogURL = repositoryRoot.appending(path: "KnitNoteWatch/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(catalog["strings"] as? [String: Any])
    }

    private func shareCatalogStrings() throws -> [String: Any] {
        let catalogURL = repositoryRoot.appending(path: "KnitNoteShare/Localizable.xcstrings")
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
        let stringUnit: [String: Any]
        if let directStringUnit = translation["stringUnit"] as? [String: Any] {
            stringUnit = directStringUnit
        } else {
            let variations = try #require(translation["variations"] as? [String: Any])
            let plural = try #require(variations["plural"] as? [String: Any])
            let other = try #require(plural["other"] as? [String: Any])
            stringUnit = try #require(other["stringUnit"] as? [String: Any])
        }
        return try #require(stringUnit["value"] as? String)
    }

    private func pluralizedValue(
        _ key: String,
        language: String,
        count: Int,
        strings: [String: Any]
    ) throws -> String {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let translation = try #require(localizations[language] as? [String: Any])
        let variations = try #require(translation["variations"] as? [String: Any])
        let plural = try #require(variations["plural"] as? [String: Any])
        let category = language == "en" && count == 1 ? "one" : "other"
        let variation = try #require(plural[category] as? [String: Any])
        let stringUnit = try #require(variation["stringUnit"] as? [String: Any])
        let format = try #require(stringUnit["value"] as? String)
        return String.localizedStringWithFormat(format, count)
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

    private func isTask13PatternKey(_ key: String) -> Bool {
        task13PatternPrefixes.contains { key.hasPrefix($0) }
            || task13StandalonePatternKeys.contains(key)
    }

    private func task13PatternSourceKeys() throws -> Set<String> {
        try localizationKeys(
            in: [
                "KnitNote/App/RootView.swift",
                "KnitNote/Patterns/ChooseLibraryPatternView.swift",
                "KnitNote/Patterns/ChoosePatternReadingContextView.swift",
                "KnitNote/Patterns/PatternDetailView.swift",
                "KnitNote/Patterns/PatternImportResultView.swift",
                "KnitNote/Patterns/PatternInboxProcessor.swift",
                "KnitNote/Patterns/PatternLibraryRow.swift",
                "KnitNote/Patterns/PatternLibraryView.swift",
                "KnitNote/Patterns/PendingPatternSelectionView.swift",
                "KnitNote/Patterns/ProjectPatternsView.swift",
                "KnitNote/Settings/BackupSettingsSection.swift",
            ],
            matching: #"(?:patterns|backup)\.[A-Za-z0-9._-]+"#
        )
    }

    private func localizationKeys(
        in relativePaths: [String],
        matching pattern: String
    ) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: pattern)
        return try Set(relativePaths.flatMap { relativePath in
            let source = try String(
                contentsOf: repositoryRoot.appending(path: relativePath),
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
