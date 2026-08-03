#if os(macOS)
import Foundation
import Testing
@testable import KnitNote

@Suite struct MacYarnLabelFileImporterTests {
    @Test func importsSupportedImageByCopyingItsData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "label.png")
        let data = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try data.write(to: url)

        let imported = try MacYarnLabelFileImporter().load([url])

        #expect(imported == [data])
    }

    @Test func rejectsUnsupportedFileAndMoreThanTwoSelections() throws {
        let textURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).txt")
        try Data("not an image".utf8).write(to: textURL)
        defer { try? FileManager.default.removeItem(at: textURL) }

        #expect(throws: MacYarnLabelFileImportError.self) {
            try MacYarnLabelFileImporter().load([textURL])
        }
        #expect(throws: MacYarnLabelFileImportError.self) {
            try MacYarnLabelFileImporter().load([textURL, textURL, textURL])
        }
    }
}
#endif
