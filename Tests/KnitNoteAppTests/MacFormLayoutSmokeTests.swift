import Foundation
import Testing
@testable import KnitNote

@Suite struct MacFormLayoutSmokeTests {
    @Test func macFormLayoutSourcesExposeTheRequiredAdaptiveStructure() throws {
        let settings = try source(named: "SettingsView.swift", in: "Settings")
        let project = try source(named: "CreateProjectView.swift", in: "Projects")
        let photoPicker = try source(named: "ProjectPhotoPicker.swift", in: "Projects")

        #expect(settings.contains("#if os(macOS)"))
        #expect(settings.contains("GeometryReader { proxy in"))
        #expect(settings.contains("min(max(proxy.size.width - 48, 0), 720)"))
        #expect(project.contains("minWidth: 520"))
        #expect(project.contains("idealWidth: 620"))
        #expect(project.contains("minHeight: 560"))
        #expect(photoPicker.contains("ViewThatFits"))
    }

    private func source(named name: String, in directory: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("KnitNote/\(directory)/\(name)"),
            encoding: .utf8
        )
    }
}
