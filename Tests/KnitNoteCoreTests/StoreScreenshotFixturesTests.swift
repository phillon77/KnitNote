import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct StoreScreenshotFixturesTests {
    @Test func fixturesAreDeterministicAndComplete() throws {
        let first = try StoreScreenshotFixtures.make(language: .zhHant)
        let second = try StoreScreenshotFixtures.make(language: .zhHant)

        #expect(try first.archiveData() == second.archiveData())
        #expect(first.files == second.files)
        #expect(first.archive.version == ProjectArchive.currentVersion)
        #expect(first.archive.projects.count == 2)
        #expect(first.archive.projects.allSatisfy { $0.counters.count == 6 })
        #expect(first.archive.projects[0].counters.map(\.value) == [38, 6, 12, 4, 18, 16])
        #expect(first.archive.projects[0].patterns.count == 1)
        #expect(first.archive.projects[0].journalEntries.count == 2)
        #expect(first.archive.yarns.count == 3)
        #expect(first.files.keys.contains { $0.hasSuffix(".pdf") })
        #expect(first.files.keys.contains { $0.contains("/Markup/") && $0.hasSuffix(".json") })
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
        #expect(store.projects.first?.patterns.count == 1)
        #expect(store.yarns.count == 3)
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
}
