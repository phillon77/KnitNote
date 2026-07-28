import Foundation
import Testing

@Suite struct KnittingCalculatorMetadataContractTests {
    private let productURL = "https://phillon77.github.io/KnitNote/knitting-calculator.html"
    private let privacyURL = "https://phillon77.github.io/KnitNote/knitting-calculator-privacy.html"

    @Test func freeAppMetadataIsCompleteAccurateAndLocalized() throws {
        let expected = [
            "en-US": ("Knitting Calculator", "Gauge, Increases & Decreases", ["crochet", "stitch", "rows", "needle", "yarn", "pattern", "swatch", "math", "craft"]),
            "zh-Hant": ("編織計算器", "密度與加減針工具", ["棒針", "鉤針", "針數", "排數", "毛線", "針目", "樣本", "尺寸", "換算", "間隔"]),
        ]

        for (locale, values) in expected {
            let fields = try metadataFields(for: locale)
            for name in ["Name", "Subtitle", "Promotional text", "Keywords", "Description", "Support URL", "Privacy URL", "What's New", "Review Notes", "Territory positioning"] {
                #expect(!(fields[name] ?? "").isEmpty, "\(locale) is missing \(name)")
            }
            #expect(fields["Name"] == values.0)
            #expect(fields["Subtitle"] == values.1)
            #expect(fields["Support URL"] == productURL)
            #expect(fields["Privacy URL"] == privacyURL)
            #expect((fields["Name"] ?? "").count <= 30)
            #expect((fields["Subtitle"] ?? "").count <= 30)
            #expect((fields["Promotional text"] ?? "").count <= 170)
            #expect((fields["Keywords"] ?? "").utf8.count <= 100)
            #expect((fields["Keywords"] ?? "").contains(","))
            for keyword in values.2 {
                #expect((fields["Keywords"] ?? "").localizedCaseInsensitiveContains(keyword))
            }

            let text = try source("AppStore/KnittingCalculator/Metadata/\(locale).md")
            #expect(!text.localizedCaseInsensitiveContains("upgrade"))
            #expect(!text.localizedCaseInsensitiveContains("full version"))
            #expect(!text.contains("完整版"))
            #expect(text.localizedCaseInsensitiveContains("free") || text.contains("免費"))
            #expect(text.localizedCaseInsensitiveContains("offline") || text.contains("離線"))
            #expect(text.localizedCaseInsensitiveContains("account") || text.contains("帳號"))
            #expect(text.range(of: "KnitNote", options: .caseInsensitive) != nil)
        }
    }

    @Test func keywordsDoNotRepeatNameSubtitleOrLocalCategoryTerms() throws {
        for locale in ["en-US", "zh-Hant"] {
            let fields = try metadataFields(for: locale)
            let reserved = normalized(fields["Name"] ?? "")
                + normalized(fields["Subtitle"] ?? "")
                + normalized(fields["Primary Category"] ?? "")
                + normalized(fields["Secondary Category"] ?? "")
            for keyword in (fields["Keywords"] ?? "").split(separator: ",") {
                let normalizedKeyword = normalized(String(keyword))
                #expect(!normalizedKeyword.isEmpty)
                #expect(!reserved.contains(normalizedKeyword), "\(locale) keyword repeats a name, subtitle, or category term: \(keyword)")
            }
        }
    }

    @Test func privacyAndSupportMatchTheNoCollectionAppManifest() throws {
        let manifest = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: metadataRepositoryRoot.appending(path: "KnittingCalculator/PrivacyInfo.xcprivacy")),
            format: nil
        ) as? [String: Any]
        #expect(manifest?["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest?["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        #expect((manifest?["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.isEmpty == true)
        let apiTypes = manifest?["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        #expect(apiTypes?.count == 1)
        #expect(apiTypes?.first?["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults")
        #expect(apiTypes?.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["CA92.1"])

        let policy = try source("AppStore/KnittingCalculator/PrivacyPolicy.md")
        for claim in ["does not collect", "不蒐集", "on your device", "裝置", "no account", "不需要帳號", "no ads", "不含廣告", "no analytics", "不含分析", "does not track", "不會追蹤", "UserDefaults", "delete"] {
            #expect(policy.localizedCaseInsensitiveContains(claim), "privacy policy is missing \(claim)")
        }

        for page in ["AppStore/SupportSite/knitting-calculator.html", "AppStore/SupportSite/knitting-calculator-privacy.html"] {
            let text = try source(page)
            #expect(text.contains("mailto:lzz.1999@icloud.com"))
            #expect(text.contains(productURL))
            #expect(text.contains(privacyURL))
            #expect(!text.contains("http://"))
        }
        let home = try source("AppStore/SupportSite/index.html")
        #expect(home.contains("knitting-calculator.html"))
        #expect(home.contains("knitting-calculator-privacy.html"))
    }

    @Test func calculatorTargetHasNoNetworkSDKOrPermissionDeclarations() throws {
        let sourceFiles = try FileManager.default.subpathsOfDirectory(atPath: metadataRepositoryRoot.appending(path: "KnittingCalculator").path)
            .filter { $0.hasSuffix(".swift") || $0.hasSuffix(".plist") || $0.hasSuffix(".xcprivacy") }
        let targetSource = try sourceFiles
            .map { try source("KnittingCalculator/\($0)") }
            .joined(separator: "\n")
        for forbidden in ["URLSession", "NWConnection", "Firebase", "Analytics", "Telemetry", "AppTrackingTransparency", "NSCameraUsageDescription", "NSPhotoLibraryUsageDescription", "NSUserNotificationUsageDescription", "NSLocation", "NSContacts"] {
            #expect(!targetSource.localizedCaseInsensitiveContains(forbidden), "calculator target must not declare \(forbidden)")
        }
    }

    private func metadataFields(for locale: String) throws -> [String: String] {
        let text = try source("AppStore/KnittingCalculator/Metadata/\(locale).md")
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("- ") else { continue }
            let remainder = line.dropFirst(2)
            guard let separator = remainder.firstIndex(of: ":") else { continue }
            let name = String(remainder[..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            fields[name] = value
        }
        return fields
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: metadataRepositoryRoot.appending(path: relativePath), encoding: .utf8)
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

private let metadataRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
