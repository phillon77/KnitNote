import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnitNoteBackupManifestTests {
    @Test func versionOneRoundTripsAndBuildsPreview() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let manifest = KnitNoteBackupManifest(
            formatVersion: 1,
            createdAt: date,
            appVersion: "1.0.0",
            projectCount: 2,
            yarnCount: 3
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(try decoded.preview() == .init(createdAt: date, projectCount: 2, yarnCount: 3))
        #expect(try decoded.preview().patternCount == nil)
    }

    @Test func versionTwoRoundTripsFileIntegrityAndBuildsPatternPreview() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let files = [
            KnitNoteBackupManifestFile(
                relativePath: "projects-v1.json",
                byteCount: 123,
                sha256: String(repeating: "a", count: 64)
            ),
            KnitNoteBackupManifestFile(
                relativePath: "Patterns/Assets/pattern.pdf",
                byteCount: 456,
                sha256: String(repeating: "b", count: 64)
            ),
        ]
        let manifest = KnitNoteBackupManifest(
            formatVersion: 2,
            createdAt: date,
            appVersion: "1.2.0",
            projectCount: 2,
            yarnCount: 3,
            patternCount: 4,
            files: files,
            criticalFeatures: [KnitNoteBackupManifest.fileIntegrityFeature]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: data)

        #expect(decoded == manifest)
        #expect(
            try decoded.preview()
                == .init(createdAt: date, projectCount: 2, yarnCount: 3, patternCount: 4)
        )
        #expect(decoded.files == files)
    }

    @Test func newerFormatIsRejected() {
        let manifest = KnitNoteBackupManifest(
            formatVersion: 3,
            createdAt: .now,
            appVersion: "2.0",
            projectCount: 0,
            yarnCount: 0
        )
        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(3)) {
            try manifest.preview()
        }
    }

    @Test func exportPackageWritesANamedDirectoryWithItsContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("Source.knitnote-backup", isDirectory: true)
        let sourceData = source.appendingPathComponent("Data", isDirectory: true)
        let destination = root.appendingPathComponent("Saved.knitnote-backup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: sourceData, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("archive".utf8).write(to: sourceData.appendingPathComponent("projects-v1.json"))

        let package = try KnitNoteBackupExportPackage(
            packageURL: source,
            preferredFilename: "KnitNote-2026-07-20.knitnote-backup"
        )
        let wrapper = try package.fileWrapper()
        try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)

        #expect(wrapper.isDirectory)
        #expect(wrapper.filename == nil)
        #expect(wrapper.preferredFilename == "KnitNote-2026-07-20.knitnote-backup")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Data/projects-v1.json").path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("manifest.json")) == Data("manifest".utf8))
    }
}
