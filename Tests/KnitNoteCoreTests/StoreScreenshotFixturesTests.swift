import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct StoreScreenshotFixturesTests {
    @Test func screenshotLanguagesReuseOneByteIdenticalUserAuthoredPayload() throws {
        #expect(StoreScreenshotLanguage.allCases.map(\.rawValue) == releaseScreenshotLocales)

        let neutral = try StoreScreenshotFixtures.make(language: .en)
        let neutralArchive = try neutral.archiveData()
        for language in StoreScreenshotLanguage.allCases {
            let localized = try StoreScreenshotFixtures.make(language: language)
            #expect(try localized.archiveData() == neutralArchive)
            #expect(localized.files == neutral.files)
        }
    }

    @Test func watchScreenshotLanguagesReuseOneIdenticalUserAuthoredPayload() throws {
        let neutral = try StoreScreenshotFixtures.makeWatchFixture(language: .en)

        for language in StoreScreenshotLanguage.allCases {
            let localized = try StoreScreenshotFixtures.makeWatchFixture(language: language)
            #expect(localized.projectID == neutral.projectID)
            #expect(localized.cache == neutral.cache)
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
            "da": [
                "1|watch-sync|Tæl fra håndleddet. Fortsæt med at strikke.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|Læs opskrifter. Hold alle tællere synkroniseret.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|Seks tællere. Ét roligt arbejdsområde.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|Prøv alle funktioner gratis i 7 dage.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|Projekter, garn og noter – samlet ét sted.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|Ét køb. Alle dine Apple-enheder.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
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
            "el": [
                "1|watch-sync|Μετρήστε από τον καρπό. Συνεχίστε το πλέξιμο.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|Διαβάστε σχέδια. Κρατήστε όλους τους μετρητές συγχρονισμένους.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|Έξι μετρητές. Ένας ήρεμος χώρος εργασίας.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|Δοκιμάστε όλες τις λειτουργίες δωρεάν για 7 ημέρες.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|Έργα, νήματα και σημειώσεις — όλα μαζί.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|Μία αγορά. Όλες οι συσκευές Apple σας.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
            "fi": [
                "1|watch-sync|Laske ranteesta. Jatka neulomista.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|Lue ohjeita. Pidä kaikki laskurit synkronoituina.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|Kuusi laskuria. Yksi rauhallinen työtila.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|Kokeile kaikkia ominaisuuksia maksutta 7 päivää.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|Projektit, langat ja muistiinpanot – kaikki yhdessä.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|Yksi osto. Kaikki Apple-laitteesi.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
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
            "ko": [
                "1|watch-sync|손목에서 세고, 뜨개질을 계속하세요.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|도안을 읽고, 모든 카운터를 동기화하세요.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|6개 카운터. 차분한 작업 공간.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|모든 기능을 7일 동안 무료로 사용해 보세요.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|프로젝트, 실, 메모를 한곳에.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|한 번 구매로 모든 Apple 기기에서.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
            "nb": [
                "1|watch-sync|Tell fra håndleddet. Fortsett å strikke.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|Les mønstre. Hold alle tellerne synkronisert.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|Seks tellere. Ett rolig arbeidsområde.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|Prøv alle funksjonene gratis i 7 dager.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|Prosjekter, garn og notater – alt samlet.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|Ett kjøp. Alle Apple-enhetene dine.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
            ],
            "sv": [
                "1|watch-sync|Räkna från handleden. Fortsätt sticka.|01-watch-sync.png|Apple Watch+iPhone",
                "2|pattern-sync|Läs mönster. Håll alla räknare synkroniserade.|02-pattern-sync.png|iPad+iPhone+PDF",
                "3|six-counters|Sex räknare. En lugn arbetsyta.|03-six-counters.png|iPhone+six named counters",
                "4|seven-day-trial|Prova alla funktioner gratis i 7 dagar.|04-seven-day-trial.png|trial+7 days",
                "5|organized-workspace|Projekt, garn och anteckningar – allt samlat.|05-organized-workspace.png|projects+yarn+notes",
                "6|one-purchase|Ett köp. Alla dina Apple-enheter.|06-one-purchase.png|one purchase+iPhone+iPad+Mac+Apple Watch",
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
            let result = try screenshotCaptureProcess(locale: locale)
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
        #expect(validation.output.contains("168 screenshot definitions valid"))
    }

    @Test func captureEntrypointIgnoresArmedParentEnvironment() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "knitnote-capture-environment-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeBin = root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let marker = root.appending(path: "xcrun-was-invoked")
        let fakeXcrun = fakeBin.appending(path: "xcrun")
        try """
        #!/bin/sh
        : > "${MARKER_FILE:?}"
        exit 99
        """.write(to: fakeXcrun, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fakeXcrun.path
        )

        var armedEnvironment = ProcessInfo.processInfo.environment
        let existingPath = armedEnvironment["PATH"] ?? "/usr/bin:/bin"
        armedEnvironment.merge([
            "PATH": "\(fakeBin.path):\(existingPath)",
            "MARKER_FILE": marker.path,
            "IPHONE_UDID": "armed-iphone",
            "IPAD_UDID": "armed-ipad",
            "WATCH_UDID": "armed-watch",
            "IOS_APP": "/armed/KnitNote.app",
            "WATCH_APP": "/armed/KnitNoteWatch.app",
            "MAC_APP": "/armed/KnitNote.app",
        ]) { _, armed in armed }

        let result = try screenshotCaptureProcess(
            locale: "en",
            inheritedEnvironment: armedEnvironment
        )

        #expect(result.status == 2)
        #expect(result.output.contains("IPHONE_UDID must identify"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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

private func screenshotCaptureProcess(
    locale: String,
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
) throws -> ScreenshotProcessResult {
    var sanitizedEnvironment = inheritedEnvironment
    for key in [
        "IPHONE_UDID",
        "IPAD_UDID",
        "WATCH_UDID",
        "IOS_APP",
        "WATCH_APP",
        "MAC_APP",
    ] {
        sanitizedEnvironment.removeValue(forKey: key)
    }
    return try screenshotProcess(
        executable: "/bin/bash",
        arguments: ["AppStore/Screenshots/capture.sh", locale],
        environment: sanitizedEnvironment
    )
}

private func screenshotProcess(
    executable: String,
    arguments: [String],
    currentDirectory: URL = screenshotRepositoryRoot,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> ScreenshotProcessResult {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.environment = environment
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

private let releaseScreenshotLocales = [
    "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
    "nb", "sv", "fi", "da", "ko", "el",
]
