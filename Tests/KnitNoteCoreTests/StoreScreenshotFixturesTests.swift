import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct StoreScreenshotFixturesTests {
    @Test func screenshotLanguagesCoverTheSixReleaseLocalesWithoutTranslatingFixtureData() throws {
        #expect(StoreScreenshotLanguage.allCases.map(\.rawValue) == releaseScreenshotLocales)

        let english = try StoreScreenshotFixtures.make(language: .en).archive
        for language in StoreScreenshotLanguage.allCases
        where !["en", "zh-Hant"].contains(language.rawValue) {
            let localized = try StoreScreenshotFixtures.make(language: language).archive
            #expect(localized.projects.map(\.name) == english.projects.map(\.name))
            #expect(
                localized.projects.flatMap { $0.counters.map(\.customName) }
                    == english.projects.flatMap { $0.counters.map(\.customName) }
            )
            #expect(localized.patterns.map(\.displayName) == english.patterns.map(\.displayName))
            #expect(localized.yarns.map(\.name) == english.yarns.map(\.name))
        }
    }

    @Test func fixturesAreDeterministicAndComplete() throws {
        let first = try StoreScreenshotFixtures.make(language: .zhHant)
        let second = try StoreScreenshotFixtures.make(language: .zhHant)

        #expect(try first.archiveData() == second.archiveData())
        #expect(first.files == second.files)
        #expect(first.archive.version == ProjectArchive.currentVersion)
        #expect(first.archive.projects.count == 2)
        #expect(first.archive.projects.allSatisfy { $0.counters.count == 6 })
        #expect(first.archive.projects[0].counters.map(\.value) == [38, 6, 12, 4, 18, 16])
        #expect(first.archive.projects[0].patterns.isEmpty)
        #expect(first.archive.patternAssets.count == 1)
        #expect(first.archive.patterns.count == 1)
        #expect(first.archive.patternUsages.count == 1)
        #expect(first.archive.projects[0].journalEntries.count == 2)
        #expect(first.archive.yarns.count == 3)
        #expect(first.files.keys.contains { $0.hasSuffix(".pdf") })
        #expect(first.files.keys.contains { $0.contains("/UsageMarkup/") && $0.hasSuffix(".json") })
    }

    @Test func fixturesContainNoPersonalOrProductionDeviceData() throws {
        let packages = try StoreScreenshotLanguage.allCases.map {
            try StoreScreenshotFixtures.make(language: $0)
        }
        let forbidden = ["lzz.1999", "/Users/", "IMG_", "截圖", "GPS", "FamilyKnittingHero"]

        for package in packages {
            let archiveText = try #require(String(data: package.archiveData(), encoding: .utf8))
            let filenames = package.files.keys.joined(separator: "\n")
            for value in forbidden {
                #expect(!archiveText.localizedCaseInsensitiveContains(value))
                #expect(!filenames.localizedCaseInsensitiveContains(value))
                #expect(package.files.values.allSatisfy { data in
                    !String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains(value)
                })
            }
        }
    }

    @Test func visualFixturesAreRealSwatchesAndLanguageNeutralCharts() throws {
        let fixture = try StoreScreenshotFixtures.make(language: .zhHant)
        let imagePayloads = fixture.files.filter { !$0.key.hasSuffix(".pdf") && !$0.key.hasSuffix(".json") }
        #expect(!imagePayloads.isEmpty)
        #expect(imagePayloads.values.allSatisfy { $0.count > 400 })

        let pdf = try #require(fixture.files.first { $0.key.hasSuffix(".pdf") }?.value)
        let pdfText = String(decoding: pdf, as: UTF8.self)
        #expect(!pdfText.contains("Cloud Shawl"))
        #expect(!pdfText.contains("Rows"))
        #expect(!pdfText.contains("Finishing"))
    }

    @Test func installationWritesOnlyInsideTheRequestedTemporaryRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "knitnote-store-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try StoreScreenshotFixtures.make(language: .en)
        let baseDirectory = try package.install(in: root)

        #expect(baseDirectory == root)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "KnitNote/projects-v1.json").path))
        for relativePath in package.files.keys {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "KnitNote/\(relativePath)").path))
        }
    }

    @Test @MainActor func installedFixtureLoadsThroughTheProductionStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "knitnote-store-load-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try StoreScreenshotFixtures.make(language: .en)
        _ = try JSONDecoder().decode(ProjectArchive.self, from: fixture.archiveData())
        let baseDirectory = try fixture.install(in: root)
        let directStore = JSONProjectStore(
            url: baseDirectory.appending(path: "KnitNote/projects-v1.json")
        )
        #expect(directStore.loadError == nil)
        #expect(directStore.projects.count == 2)
        let store = JSONProjectStore.live(baseDirectory: baseDirectory)

        #expect(store.loadError == nil)
        #expect(store.projects.count == 2)
        #expect(store.projects.first?.counters.count == 6)
        #expect(store.projects.first?.patterns.isEmpty == true)
        #expect(store.patternAssets.count == 1)
        #expect(store.patterns.count == 1)
        #expect(store.patternUsages.count == 1)
        #expect(store.yarns.count == 3)
    }

    @Test @MainActor func installedFixtureProvidesArchiveLevelReaderContentAndUsageMarkup() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "knitnote-store-reader-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let baseDirectory = try StoreScreenshotFixtures.make(language: .en).install(in: root)
        let store = JSONProjectStore.live(baseDirectory: baseDirectory)
        let asset = try #require(store.patternAssets.first)
        let pattern = try #require(store.patterns.first)
        let usage = try #require(store.patternUsages.first { $0.isActive })

        #expect(store.projects.first?.patterns.isEmpty == true)
        #expect(pattern.assetID == asset.id)
        #expect(usage.patternID == pattern.id)
        #expect(usage.projectID == store.projects.first?.id)
        #expect(FileManager.default.fileExists(atPath: try store.patternAssetURL(patternID: pattern.id).path))
        #expect(!(try store.loadPatternMarkup(usageID: usage.id, pageIndex: 0)).strokes.isEmpty)
    }

    @Test func everyApprovedScreenshotSceneHasAStableLaunchValue() {
        #expect(StoreScreenshotScene.allCases.map(\.rawValue) == [
            "projects",
            "counters",
            "patternHighlight",
            "patternCrossHighlight",
            "patternMarkup",
            "patternNotes",
            "journal",
            "yarn",
            "calculators",
        ])
    }

    @Test func releaseStoryboardUsesTheApprovedSixImageOrder() throws {
        let expected: [String: [String]] = [
            "de": [
                "1|watch-sync|Am Handgelenk zählen. Einfach weiterstricken.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|Muster lesen. Alle Zähler synchron halten.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|Sechs Zähler. Ein ruhiger Arbeitsbereich.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|Alle Funktionen 7 Tage kostenlos testen.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|Projekte, Garn und Notizen – alles zusammen.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|Ein Kauf. Alle deine Apple-Geräte.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
            "en": [
                "1|watch-sync|Count from your wrist. Keep knitting.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|Read patterns. Keep every count in sync.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|Six counters. One calm workspace.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|Try everything free for 7 days.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|Projects, yarn, notes—all together.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|One purchase. All your Apple devices.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
            "fr": [
                "1|watch-sync|Comptez au poignet. Continuez à tricoter.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|Lisez vos patrons. Gardez chaque compteur synchronisé.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|Six compteurs. Un espace apaisant.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|Essayez toutes les fonctions pendant 7 jours.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|Ouvrages, fils et notes, tous réunis.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|Un achat. Tous vos appareils Apple.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
            "ja": [
                "1|watch-sync|手首で数えて、編み物に集中。|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|編み図を読み、すべてのカウントを同期。|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|6つのカウンター。落ち着いた作業スペース。|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|すべての機能を7日間無料でお試し。|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|作品、毛糸、メモをひとまとめに。|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|1回の購入で、すべてのAppleデバイスに。|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
            "zh-Hans": [
                "1|watch-sync|从手腕计数，编织不中断。|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|阅读图解，让每个计数器保持同步。|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|6 个计数器，一个安静的工作空间。|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|完整功能免费试用 7 天。|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|作品、毛线、笔记，全部集中管理。|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|一次购买，解锁所有 Apple 设备。|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
            "zh-Hant": [
                "1|watch-sync|從手腕計數，編織不中斷。|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|閱讀織圖，每組計數保持同步。|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|六組計數器，一個安靜工作區。|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|完整功能免費試用 7 天。|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|作品、毛線、筆記，全都在一起。|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|一次購買，解鎖所有 Apple 裝置。|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
        ]

        let data = try Data(
            contentsOf: screenshotRepositoryRoot.appending(path: "AppStore/Screenshots/manifest.json")
        )
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let storyboard = try #require(payload["releaseStoryboard"] as? [[String: Any]])

        for locale in releaseScreenshotLocales {
            let actual = storyboard
                .filter { $0["locale"] as? String == locale }
                .map(storyboardContractLine)
            #expect(actual == expected[locale])
            #expect(try releasePlanOutput(locale: locale) == expected[locale]?.joined(separator: "\n"))
        }
    }

    @Test func manifestValidatorAndCaptureEntrypointSupportEveryReleaseLocale() throws {
        let data = try Data(
            contentsOf: screenshotRepositoryRoot.appending(path: "AppStore/Screenshots/manifest.json")
        )
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frames = try #require(payload["frames"] as? [[String: Any]])

        #expect(frames.count == releaseScreenshotLocales.count * 14)
        #expect(Set(frames.compactMap { $0["locale"] as? String }) == Set(releaseScreenshotLocales))
        for locale in releaseScreenshotLocales {
            #expect(frames.filter { $0["locale"] as? String == locale }.count == 14)
            let result = try screenshotProcess(
                executable: "/bin/bash",
                arguments: ["AppStore/Screenshots/capture.sh", locale]
            )
            #expect(result.status == 2)
            #expect(result.output.contains("IPHONE_UDID must identify"))
            #expect(!result.output.contains("usage:"))
        }

        let validation = try screenshotProcess(
            executable: "/usr/bin/env",
            arguments: [
                "python3",
                "AppStore/Screenshots/validate.py",
                "AppStore/Screenshots/manifest.json",
                "--manifest-only",
            ]
        )
        #expect(validation.status == 0)
        #expect(validation.output.contains("84 screenshot definitions valid"))
    }

    @Test func composerCreatesAContactSheetForEveryManifestLocale() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "knitnote-six-locale-compose-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let frames: [[String: Any]] = try releaseScreenshotLocales.map { locale in
            let raw = root
                .appending(path: "Raw/\(locale)/iphone", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            var image = Data("P6\n100 200\n255\n".utf8)
            image.append(Data(repeating: 255, count: 100 * 200 * 3))
            try image.write(to: raw.appending(path: "01.png"))
            return [
                "locale": locale,
                "platform": "iphone",
                "scene": "projects",
                "device": "fixture",
                "width": 100,
                "height": 200,
                "headline": locale,
                "filename": "01.png",
            ]
        }
        let manifest = root.appending(path: "manifest.json")
        try JSONSerialization.data(withJSONObject: ["frames": frames])
            .write(to: manifest)

        let result = try screenshotProcess(
            executable: "/usr/bin/env",
            arguments: [
                "python3",
                screenshotRepositoryRoot.appending(path: "AppStore/Screenshots/compose.py").path,
                manifest.path,
            ],
            currentDirectory: root
        )

        #expect(result.status == 0)
        for locale in releaseScreenshotLocales {
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appending(path: "Generated/\(locale)/contact-sheet.jpg").path
                )
            )
        }
    }

    @Test func rawCapturePlanPutsTheWatchFixtureFirst() throws {
        let script = try screenshotSourceText("AppStore/Screenshots/capture.sh")

        #expect(script.contains("\"watch\": 0"))
        #expect(script.contains("sorted(localized, key="))
        #expect(script.contains("watchProjects"))
    }
}

private func storyboardContractLine(_ item: [String: Any]) -> String {
    let order = item["order"] as? Int ?? -1
    let id = item["id"] as? String ?? ""
    let headline = item["headline"] as? String ?? ""
    let filename = item["filename"] as? String ?? ""
    let requiredVisuals = item["requiredVisuals"] as? [String] ?? []
    return "\(order)|\(id)|\(headline)|\(filename)|\(requiredVisuals.joined(separator: "+"))"
}

private func releasePlanOutput(locale: String) throws -> String {
    let result = try screenshotProcess(
        executable: "/bin/bash",
        arguments: [
        "AppStore/Screenshots/capture.sh",
        "--release-plan",
        locale,
        ]
    )
    #expect(result.status == 0)
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct ScreenshotProcessResult {
    let status: Int32
    let output: String
}

private func screenshotProcess(
    executable: String,
    arguments: [String],
    currentDirectory: URL = screenshotRepositoryRoot
) throws -> ScreenshotProcessResult {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    return ScreenshotProcessResult(
        status: process.terminationStatus,
        output: String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}

private func screenshotSourceText(_ relativePath: String) throws -> String {
    try String(
        contentsOf: screenshotRepositoryRoot.appending(path: relativePath),
        encoding: .utf8
    )
}

private let screenshotRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let releaseScreenshotLocales = ["en", "zh-Hant", "zh-Hans", "de", "fr", "ja"]
