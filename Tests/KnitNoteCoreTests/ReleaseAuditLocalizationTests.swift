import Foundation
import Testing

@Suite(.serialized) struct ReleaseAuditLocalizationTests {
    @Test func archiveAuditRejectsOneMissingJapaneseWatchLocalizationDirectory() throws {
        let fixture = try makeArchiveFixture(
            omittingDirectory: (target: "Watch", locale: "ja")
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Watch bundle is missing ja.lproj"))
    }

    @Test func archiveAuditRejectsExtraSpanishWatchLocalizationDirectory() throws {
        let fixture = try makeArchiveFixture(
            extraDirectory: (target: "Watch", locale: "es")
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Watch bundle localization directories do not match"))
    }

    @Test func archiveAuditRejectsShareBundleWhoseDeclaredLocalizationsAreIncomplete() throws {
        let fixture = try makeArchiveFixture(
            localizationOverrides: ["Share": releaseLocales.filter { $0 != "fr" }]
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Share CFBundleLocalizations do not match"))
    }

    @Test func archiveAuditRejectsPreviousVersionAcrossShippingProducts() throws {
        let fixture = try makeArchiveFixture(version: "1.3.1", build: "8")
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("iOS product version is 1.3.1, expected 1.4.1"))
    }

    @Test func archiveAuditRejectsPreviousBuildAcrossShippingProducts() throws {
        let fixture = try makeArchiveFixture(version: "1.4.1", build: "7")
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("iOS product build is 7, expected 8"))
    }

    @Test func staticAuditRejectsGeneratedProjectMissingOneReleaseRegion() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-project-regions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let project = temporaryRoot.appendingPathComponent("project.pbxproj")
        try """
        developmentRegion = en;
        knownRegions = (
            Base,
            de,
            en,
            fr,
            "zh-Hans",
            "zh-Hant",
        );
        """.write(to: project, atomically: true, encoding: .utf8)

        let result = try runReleaseAudit(
            environment: ["KNITNOTE_PROJECT_FILE": project.path]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("project knownRegions do not match"))
    }

    @Test func staticAuditRejectsAnyAdditionalTopLevelSharedBuildableProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knitnote-project-inventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, schemeNames) in [
            ("KnitNote.xcodeproj", ["KnitNote", "KnitNoteWatch", "KnitNoteShare"]),
            ("Archive.xcodeproj", ["KnitNote"]),
        ] {
            let schemes = root.appendingPathComponent(name).appendingPathComponent("xcshareddata/xcschemes")
            try FileManager.default.createDirectory(
                at: schemes,
                withIntermediateDirectories: true
            )
            for schemeName in schemeNames {
                try "<Scheme/>".write(
                    to: schemes.appendingPathComponent("\(schemeName).xcscheme"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        let result = try runReleaseAudit(environment: ["KNITNOTE_PROJECT_SCAN_ROOT": root.path])
        #expect(result.status != 0)
        #expect(result.output.contains("top-level Xcode project and shared scheme inventory is not canonical"))
    }

    @Test func staticAuditRejectsIncompleteInfoPlistCatalog() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-info-plist-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let catalog = temporaryRoot.appendingPathComponent("InfoPlist.xcstrings")
        let incompleteCatalog: [String: Any] = [
            "sourceLanguage": "en",
            "strings": [
                "CFBundleDisplayName": [
                    "localizations": Dictionary(
                        uniqueKeysWithValues: releaseLocales
                            .filter { $0 != "ja" }
                            .map { locale in
                                (
                                    locale,
                                    ["stringUnit": ["state": "translated", "value": "KnitNote"]]
                                )
                            }
                    ),
                ],
            ],
            "version": "1.0",
        ]
        let data = try JSONSerialization.data(withJSONObject: incompleteCatalog)
        try data.write(to: catalog)

        let result = try runReleaseAudit(
            environment: ["KNITNOTE_INFO_PLIST_CATALOG": catalog.path]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("InfoPlist.xcstrings has an incomplete twelve-locale variation"))
    }

    @Test func staticAuditRejectsInfoPlistCatalogWithExtraSpanishLocalization() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-extra-info-plist-locale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let catalog = temporaryRoot.appendingPathComponent("InfoPlist.xcstrings")
        let localizations = Dictionary(
            uniqueKeysWithValues: (releaseLocales + ["es"]).map { locale in
                (
                    locale,
                    ["stringUnit": ["state": "translated", "value": "KnitNote"]]
                )
            }
        )
        let catalogWithExtraLocale: [String: Any] = [
            "sourceLanguage": "en",
            "strings": [
                "CFBundleDisplayName": ["localizations": localizations],
            ],
            "version": "1.0",
        ]
        let data = try JSONSerialization.data(withJSONObject: catalogWithExtraLocale)
        try data.write(to: catalog)

        let result = try runReleaseAudit(
            environment: ["KNITNOTE_INFO_PLIST_CATALOG": catalog.path]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("InfoPlist.xcstrings localization key domain does not match"))
    }

    @Test func staticAuditRejectsSourceInfoPlistWithoutTwelveDeclaredLocalizations() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-source-info-plists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let main = temporaryRoot.appendingPathComponent("Main-Info.plist")
        let watch = temporaryRoot.appendingPathComponent("Watch-Info.plist")
        let share = temporaryRoot.appendingPathComponent("Share-Info.plist")
        try writePlist(["CFBundleLocalizations": releaseLocales], to: main)
        try writePlist(["CFBundleLocalizations": releaseLocales], to: watch)
        try writePlist(
            ["CFBundleLocalizations": releaseLocales.filter { $0 != "fr" }],
            to: share
        )

        let result = try runReleaseAudit(
            environment: [
                "KNITNOTE_MAIN_INFO_PLIST": main.path,
                "KNITNOTE_WATCH_INFO_PLIST": watch.path,
                "KNITNOTE_SHARE_INFO_PLIST": share.path,
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Share source CFBundleLocalizations do not match"))
    }

    @Test func archiveAuditAcceptsTwelveMatchingLocalizationsPlusBaseOnEveryShippingBundle() throws {
        let fixture = try makeArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status == 0)
        #expect(result.output.contains("TEST FIXTURE ARCHIVE AUDIT: PASS"))
        #expect(!result.output.split(separator: "\n").contains("RELEASE AUDIT: PASS"))
    }

    @Test func archiveAuditRejectsWrongRevisionEmptyLocalePrivacyDriftAndWrongSigning() throws {
        let cases: [(ArchiveFixture, String)] = [
            (try makeArchiveFixture(sourceRevision: String(repeating: "b", count: 40)), "product source revision"),
            (try makeArchiveFixture(emptyResource: ("Watch", "el")), "Localizable.strings is not a valid compiled localization table"),
            (try makeArchiveFixture(privacyTracking: true), "declares tracking or collected data"),
            (try makeArchiveFixture(privacyReasonDrift: true), "differs semantically from source"),
            (try makeArchiveFixture(signingTeam: "BADTEAM123"), "signature team is not 9CFPAUL5N5"),
            (try makeArchiveFixture(profileIdentifierOverride: "9CFPAUL5N5.com.phillon.WrongApp"), "provisioning profile is expired or is not App Store distribution"),
            (try makeArchiveFixture(profileCertificate: "different-certificate"), "signing certificate is not present"),
            (try makeArchiveFixture(provenancePathOverride: "../unrelated"), "provenance sourceCommit or deterministic archive inventory mismatch"),
            (try makeArchiveFixture(mutateAfterProvenance: true), "deterministic archive inventory mismatch"),
            (try makeArchiveFixture(profileExpired: true), "provisioning profile is expired"),
            (try makeArchiveFixture(profileMissing: true), "embedded provisioning profile is missing"),
            (try makeArchiveFixture(codesignFailure: true), "signature verification failed"),
            (try makeArchiveFixture(signedIdentifierOverride: "9CFPAUL5N5.com.phillon.WrongApp"), "signed entitlements do not match"),
            (try makeArchiveFixture(gitHead: String(repeating: "b", count: 40)), "expected source revision does not match"),
            (try makeArchiveFixture(dirtySource: true), "source worktree is dirty"),
        ]
        for (fixture, expected) in cases {
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
            let result = try runReleaseAudit(archives: fixture.archives, environment: ["PATH": fixture.commandPath])
            #expect(result.status != 0)
            #expect(result.output.contains(expected))
        }
    }

    @Test func staticAuditUsesAStaticOnlySuccessMarker() throws {
        let result = try runReleaseAudit()
        let outputLines = result.output
            .split(separator: "\n")
            .map(String.init)

        #expect(result.status == 0)
        #expect(outputLines.contains("STATIC RELEASE AUDIT: PASS"))
        #expect(!outputLines.contains("RELEASE AUDIT: PASS"))
    }

    @Test func productionAuditRejectsFixtureOverridesBeforeEmittingAPassMarker() throws {
        let result = try runReleaseAudit(
            arguments: ["--static-only"],
            environment: [:],
            productionEnvironment: ["KNITNOTE_AUDIT_GIT_ROOT": "/tmp/unrelated"]
        )
        #expect(result.status != 0)
        #expect(result.output.contains("production audit rejects override KNITNOTE_AUDIT_GIT_ROOT"))
        #expect(!result.output.contains("RELEASE AUDIT: PASS"))
    }

    @Test func supportedCandidateCreatorBindsBothSignedArchivesAndProvenanceBeforePublication() throws {
        let script = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/create_release_candidate.sh"),
            encoding: .utf8
        )
        #expect(script.contains("worktree add --detach"))
        #expect(script.components(separatedBy: "xcodebuild -project KnitNote.xcodeproj").count - 1 == 2)
        #expect(script.components(separatedBy: "KNITNOTE_SOURCE_REVISION=\"$COMMIT\" archive").count - 1 == 2)
        let provenance = try #require(script.range(of: "release_archive_manifest.py\" create"))
        let audit = try #require(script.range(of: "release_audit.sh --archives"))
        let publication = try #require(script.range(of: "mv \"$ARTIFACTS\" \"$FINAL\""))
        #expect(provenance.lowerBound < audit.lowerBound)
        #expect(audit.lowerBound < publication.lowerBound)
    }

    @Test func auditRejectsMissingContradictoryAndRepeatedModes() throws {
        for arguments in [
            [],
            ["--static-only", "--archives", "/tmp/unused-archives"],
            ["--static-only", "--static-only"],
            ["--archives", "/tmp/first", "--archives", "/tmp/second"],
        ] {
            let result = try runReleaseAudit(arguments: arguments)
            let outputLines = result.output
                .split(separator: "\n")
                .map(String.init)

            #expect(result.status == 2)
            #expect(result.output.contains("usage: release_audit.sh"))
            #expect(!outputLines.contains("STATIC RELEASE AUDIT: PASS"))
            #expect(!outputLines.contains("RELEASE AUDIT: PASS"))
        }
    }
}

private struct AuditResult {
    let status: Int32
    let output: String
}

private struct ArchiveFixture {
    let temporaryRoot: URL
    let archives: URL
    let commandPath: String
    let provenance: URL
}

private let fixtureCommit = String(repeating: "a", count: 40)

private struct BundleFixture {
    let name: String
    let bundle: URL
    let resources: URL
    let infoPlist: URL
    let identifier: String
    let companionIdentifier: String?
}

private let releaseLocales = [
    "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
    "nb", "sv", "fi", "da", "ko", "el",
]

private func runReleaseAudit(
    archives: URL? = nil,
    arguments: [String]? = nil,
    environment overrides: [String: String] = [:],
    productionEnvironment: [String: String]? = nil
) throws -> AuditResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    let modeArguments = arguments ?? archives.map {
        ["--archives", $0.path,
         "--expected-commit", fixtureCommit,
         "--provenance", $0.deletingLastPathComponent().appendingPathComponent("provenance.json").path]
    } ?? ["--static-only"]
    let isFixture = productionEnvironment == nil && (archives != nil || !overrides.isEmpty)
    process.arguments = ["AppStore/Verification/release_audit.sh"] + (isFixture ? ["--test-only"] : []) + modeArguments
    process.currentDirectoryURL = releaseAuditRepositoryRoot
    let requestedEnvironment = productionEnvironment ?? overrides
    var environment = ProcessInfo.processInfo.environment.merging(requestedEnvironment) { _, new in new }
    if let commandPath = overrides["PATH"]?.split(separator: ":").first.map(String.init) {
        environment["KNITNOTE_GIT"] = "\(commandPath)/git"
        environment["KNITNOTE_CODESIGN"] = "\(commandPath)/codesign"
        environment["KNITNOTE_SECURITY"] = "\(commandPath)/security"
        environment["KNITNOTE_SWIFT"] = "\(commandPath)/swift"
    }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    return AuditResult(
        status: process.terminationStatus,
        output: String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}

private func makeArchiveFixture(
    omittingDirectory: (target: String, locale: String)? = nil,
    extraDirectory: (target: String, locale: String)? = nil,
    localizationOverrides: [String: [String]] = [:],
    version: String = "1.4.1",
    build: String = "8",
    sourceRevision: String = fixtureCommit,
    emptyResource: (String, String)? = nil,
    privacyTracking: Bool = false,
    privacyReasonDrift: Bool = false,
    signingTeam: String = "9CFPAUL5N5",
    profileIdentifierOverride: String? = nil,
    profileCertificate: String = "certificate",
    provenancePathOverride: String? = nil,
    gitHead: String = fixtureCommit,
    dirtySource: Bool = false,
    mutateAfterProvenance: Bool = false,
    profileExpired: Bool = false,
    profileMissing: Bool = false,
    codesignFailure: Bool = false,
    signedIdentifierOverride: String? = nil
) throws -> ArchiveFixture {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("knitnote-release-audit-\(UUID().uuidString)")
    let archives = temporaryRoot.appendingPathComponent("archives")
    let iOSApp = archives.appendingPathComponent(
        "KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
    )
    let macApp = archives.appendingPathComponent(
        "KnitNote-macOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
    )
    let bundles = [
        BundleFixture(
            name: "iOS",
            bundle: iOSApp,
            resources: iOSApp,
            infoPlist: iOSApp.appendingPathComponent("Info.plist"),
            identifier: "com.phillon.KnitNote",
            companionIdentifier: nil
        ),
        BundleFixture(
            name: "Watch",
            bundle: iOSApp.appendingPathComponent("Watch/KnitNoteWatch.app"),
            resources: iOSApp.appendingPathComponent("Watch/KnitNoteWatch.app"),
            infoPlist: iOSApp.appendingPathComponent("Watch/KnitNoteWatch.app/Info.plist"),
            identifier: "com.phillon.KnitNote.watch",
            companionIdentifier: "com.phillon.KnitNote"
        ),
        BundleFixture(
            name: "Share",
            bundle: iOSApp.appendingPathComponent("PlugIns/KnitNoteShare.appex"),
            resources: iOSApp.appendingPathComponent("PlugIns/KnitNoteShare.appex"),
            infoPlist: iOSApp.appendingPathComponent("PlugIns/KnitNoteShare.appex/Info.plist"),
            identifier: "com.phillon.KnitNote.share",
            companionIdentifier: nil
        ),
        BundleFixture(
            name: "macOS",
            bundle: macApp,
            resources: macApp.appendingPathComponent("Contents/Resources"),
            infoPlist: macApp.appendingPathComponent("Contents/Info.plist"),
            identifier: "com.phillon.KnitNote",
            companionIdentifier: nil
        ),
    ]

    for item in bundles {
        try fileManager.createDirectory(at: item.resources, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": item.identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleLocalizations": localizationOverrides[item.name] ?? releaseLocales,
            "KnitNoteSourceRevision": sourceRevision,
        ]
        if let companionIdentifier = item.companionIdentifier {
            plist["WKCompanionAppBundleIdentifier"] = companionIdentifier
        }
        try writePlist(plist, to: item.infoPlist)
        var localizationDirectories = releaseLocales + ["Base"]
        if extraDirectory?.target == item.name, let extraLocale = extraDirectory?.locale {
            localizationDirectories.append(extraLocale)
        }
        for locale in localizationDirectories
        where !(omittingDirectory?.target == item.name && omittingDirectory?.locale == locale) {
            try fileManager.createDirectory(
                at: item.resources.appendingPathComponent("\(locale).lproj"),
                withIntermediateDirectories: true
            )
            let catalog: String
            switch item.name {
            case "Watch": catalog = "KnitNoteWatch/Localizable.xcstrings"
            case "Share": catalog = "KnitNoteShare/Localizable.xcstrings"
            default: catalog = "KnitNote/Localization/Localizable.xcstrings"
            }
            let catalogData = try Data(contentsOf: releaseAuditRepositoryRoot.appendingPathComponent(catalog))
            let catalogJSON = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
            let strings = try #require(catalogJSON["strings"] as? [String: Any])
            try writePlist(
                Dictionary(uniqueKeysWithValues: strings.keys.map { ($0, "localized") }),
                to: item.resources.appendingPathComponent("\(locale).lproj/Localizable.strings")
            )
            if emptyResource?.0 == item.name && emptyResource?.1 == locale {
                try Data().write(to: item.resources.appendingPathComponent("\(locale).lproj/Localizable.strings"))
            }
        }
        let sourcePrivacy: String
        switch item.name {
        case "Watch": sourcePrivacy = "KnitNoteWatch/PrivacyInfo.xcprivacy"
        case "Share": sourcePrivacy = "KnitNoteShare/PrivacyInfo.xcprivacy"
        default: sourcePrivacy = "KnitNote/PrivacyInfo.xcprivacy"
        }
        let privacyData = try Data(contentsOf: releaseAuditRepositoryRoot.appendingPathComponent(sourcePrivacy))
        var privacy = try #require(
            PropertyListSerialization.propertyList(from: privacyData, format: nil) as? [String: Any]
        )
        privacy["NSPrivacyTracking"] = privacyTracking
        if privacyReasonDrift, item.name == "iOS",
           var APIs = privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]], !APIs.isEmpty {
            APIs[0]["NSPrivacyAccessedAPITypeReasons"] = ["WRONG.1"]
            privacy["NSPrivacyAccessedAPITypes"] = APIs
        }
        try writePlist(privacy, to: item.resources.appendingPathComponent("PrivacyInfo.xcprivacy"))
        let profile = item.name == "macOS"
            ? item.bundle.appendingPathComponent("Contents/embedded.provisionprofile")
            : item.bundle.appendingPathComponent("embedded.mobileprovision")
        var profileEntitlements: [String: Any] = [
            "get-task-allow": false,
            "application-identifier": profileIdentifierOverride ?? "9CFPAUL5N5.\(item.identifier)",
        ]
        if item.name == "iOS" || item.name == "Share" {
            profileEntitlements["com.apple.security.application-groups"] = ["group.com.phillon.KnitNote"]
        }
        try writePlist(
            [
                "TeamIdentifier": ["9CFPAUL5N5"],
                "Entitlements": profileEntitlements,
                "DeveloperCertificates": [Data(profileCertificate.utf8)],
                "ExpirationDate": profileExpired ? Date(timeIntervalSince1970: 0) : Date(timeIntervalSince1970: 4_102_444_800),
            ],
            to: profile
        )
    }

    let artifacts: [(String, URL)] = [
        ("ios", iOSApp.appendingPathComponent("KnitNote")),
        ("watch", iOSApp.appendingPathComponent("Watch/KnitNoteWatch.app/KnitNoteWatch")),
        ("share", iOSApp.appendingPathComponent("PlugIns/KnitNoteShare.appex/KnitNoteShare")),
        ("macos", macApp.appendingPathComponent("Contents/MacOS/KnitNote")),
    ]
    for (_, file) in artifacts {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: file)
    }

    let fakeBin = temporaryRoot.appendingPathComponent("bin")
    try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let codesign = fakeBin.appendingPathComponent("codesign")
    let shouldFailCodesign = codesignFailure ? "yes" : "no"
    let fixtureSignedIdentifier = signedIdentifierOverride ?? ""
    try """
    #!/bin/sh
    if [ "${1:-}" = "--verify" ] && [ "\(shouldFailCodesign)" = "yes" ]; then
      exit 1
    elif [ "${1:-}" = "-dvv" ]; then
      printf '%s\n' 'Authority=Apple Distribution: Fixture (\(signingTeam))' 'TeamIdentifier=\(signingTeam)' >&2
    elif [ "${1:-}" = "-d" ] && [ "${2:-}" = "--extract-certificates" ]; then
      printf '%s' 'certificate' > "${3:?}0"
    elif [ "${1:-}" = "-d" ]; then
      case "${4:-${3:-}}" in
        *KnitNoteWatch.app) bundle='com.phillon.KnitNote.watch'; group='' ;;
        *KnitNoteShare.appex) bundle='com.phillon.KnitNote.share'; group='<key>com.apple.security.application-groups</key><array><string>group.com.phillon.KnitNote</string></array>' ;;
        *macOS*) bundle='com.phillon.KnitNote'; group='' ;;
        *) bundle='com.phillon.KnitNote'; group='<key>com.apple.security.application-groups</key><array><string>group.com.phillon.KnitNote</string></array>' ;;
      esac
      signed_id='\(fixtureSignedIdentifier)'
      [ -n "$signed_id" ] || signed_id="9CFPAUL5N5.$bundle"
      printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>application-identifier</key><string>'"$signed_id"'</string><key>com.apple.developer.team-identifier</key><string>9CFPAUL5N5</string><key>get-task-allow</key><false/>'"$group"'</dict></plist>'
    fi
    exit 0
    """.write(to: codesign, atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: codesign.path
    )
    let security = fakeBin.appendingPathComponent("security")
    try """
    #!/bin/sh
    cat "$4"
    """.write(to: security, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: security.path)
    let git = fakeBin.appendingPathComponent("git")
    try """
    #!/bin/sh
    case "$*" in
      *"rev-parse HEAD"*) printf '%s\n' '\(gitHead)' ;;
      *"status --porcelain"*) \(dirtySource ? "printf '%s\\n' ' M fixture'" : ":") ;;
      *) /usr/bin/git "$@" ;;
    esac
    """.write(to: git, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: git.path)
    let swift = fakeBin.appendingPathComponent("swift")
    try """
    #!/bin/sh
    exit 0
    """.write(to: swift, atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: swift.path
    )
    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let provenance = temporaryRoot.appendingPathComponent("provenance.json")
    for archiveName in ["KnitNote-iOS-Privacy.xcarchive", "KnitNote-macOS-Privacy.xcarchive"] {
        try writePlist(["Fixture": true], to: archives.appendingPathComponent("\(archiveName)/Info.plist"))
    }
    let manifest = Process()
    manifest.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    manifest.arguments = [
        "python3", releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/release_archive_manifest.py").path,
        "create", "--archives", archives.path, "--source-commit", fixtureCommit, "--output", provenance.path,
    ]
    try manifest.run()
    manifest.waitUntilExit()
    guard manifest.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    if provenancePathOverride != nil {
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: provenance)) as? [String: Any])
        payload["sourceCommit"] = String(repeating: "b", count: 40)
        try JSONSerialization.data(withJSONObject: payload).write(to: provenance)
    }
    if mutateAfterProvenance {
        try Data("mutated".utf8).write(to: artifacts[0].1)
    }
    if profileMissing {
        try fileManager.removeItem(at: iOSApp.appendingPathComponent("embedded.mobileprovision"))
        let regenerate = Process()
        regenerate.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        regenerate.arguments = [
            "python3", releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/release_archive_manifest.py").path,
            "create", "--archives", archives.path, "--source-commit", fixtureCommit, "--output", provenance.path,
        ]
        try regenerate.run()
        regenerate.waitUntilExit()
    }
    return ArchiveFixture(
        temporaryRoot: temporaryRoot,
        archives: archives,
        commandPath: "\(fakeBin.path):\(existingPath)",
        provenance: provenance
    )
}

private func writePlist(_ value: Any, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try PropertyListSerialization.data(
        fromPropertyList: value,
        format: .xml,
        options: 0
    )
    try data.write(to: url)
}

private let releaseAuditRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
