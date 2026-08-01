import Foundation
import Testing

@Suite struct MacFormLayoutContractTests {
    @Test func macSettingsUsesCenteredBoundedContent() throws {
        let source = try source(named: "SettingsView.swift")
        #expect(source.contains("#if os(macOS)"))
        #expect(source.contains("maxWidth: 720"))
        #expect(source.contains(".padding(.horizontal, 24)"))
    }

    @Test func macCreateProjectHasUsableMinimumSize() throws {
        let source = try source(named: "CreateProjectView.swift")
        #expect(source.contains("minWidth: 520"))
        #expect(source.contains("idealWidth: 620"))
        #expect(source.contains("minHeight: 560"))
    }

    @Test func projectPhotoActionsAdaptToNarrowWidth() throws {
        let source = try source(named: "ProjectPhotoPicker.swift")
        #expect(source.contains("ViewThatFits"))
        #expect(source.contains("HStack"))
        #expect(source.contains("VStack"))
    }

    private func source(named name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directories = ["KnitNote/Settings", "KnitNote/Projects"]
        let path = try #require(
            directories.map { root.appendingPathComponent($0).appendingPathComponent(name) }
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        )
        return try String(contentsOf: path, encoding: .utf8)
    }
}
