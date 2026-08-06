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
        #expect(result.output.contains("InfoPlist.xcstrings has an incomplete six-locale variation"))
    }

    @Test func staticAuditRejectsSourceInfoPlistWithoutSixDeclaredLocalizations() throws {
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

    @Test func archiveAuditAcceptsSixMatchingLocalizationsOnEveryShippingBundle() throws {
        let fixture = try makeArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status == 0)
        #expect(result.output.contains("RELEASE AUDIT: PASS"))
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
}

private struct BundleFixture {
    let name: String
    let bundle: URL
    let resources: URL
    let infoPlist: URL
    let identifier: String
    let companionIdentifier: String?
}

private let releaseLocales = ["en", "zh-Hant", "zh-Hans", "de", "fr", "ja"]

private func runReleaseAudit(
    archives: URL? = nil,
    environment overrides: [String: String] = [:]
) throws -> AuditResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "AppStore/Verification/release_audit.sh",
        "--static-only",
    ]
    if let archives {
        process.arguments?.append(contentsOf: ["--archives", archives.path])
    }
    process.currentDirectoryURL = releaseAuditRepositoryRoot
    process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
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
    localizationOverrides: [String: [String]] = [:]
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
            "CFBundleShortVersionString": "1.3.1",
            "CFBundleVersion": "7",
            "CFBundleLocalizations": localizationOverrides[item.name] ?? releaseLocales,
        ]
        if let companionIdentifier = item.companionIdentifier {
            plist["WKCompanionAppBundleIdentifier"] = companionIdentifier
        }
        try writePlist(plist, to: item.infoPlist)
        for locale in releaseLocales
        where !(omittingDirectory?.target == item.name && omittingDirectory?.locale == locale) {
            try fileManager.createDirectory(
                at: item.resources.appendingPathComponent("\(locale).lproj"),
                withIntermediateDirectories: true
            )
        }
        try writePlist(
            [:],
            to: item.resources.appendingPathComponent("PrivacyInfo.xcprivacy")
        )
    }

    let fakeBin = temporaryRoot.appendingPathComponent("bin")
    try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let codesign = fakeBin.appendingPathComponent("codesign")
    try """
    #!/bin/sh
    if [ "${1:-}" = "-d" ]; then
      printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>group.com.phillon.KnitNote</string></array></dict></plist>'
    fi
    exit 0
    """.write(to: codesign, atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: codesign.path
    )
    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    return ArchiveFixture(
        temporaryRoot: temporaryRoot,
        archives: archives,
        commandPath: "\(fakeBin.path):\(existingPath)"
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
