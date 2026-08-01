import Foundation
import Testing

@Suite struct MacFormLayoutContractTests {
    @Test func macSettingsUsesCenteredBoundedContent() throws {
        let source = try source(named: "SettingsView.swift")
        let macBranch = try #require(source.range(of: "#if os(macOS)"))
        let nonMacBranch = try #require(
            source.range(of: "#else", range: macBranch.upperBound..<source.endIndex)
        )
        let macEnd = try #require(
            source.range(of: "#endif", range: nonMacBranch.upperBound..<source.endIndex)
        )
        let macSource = String(source[macBranch.lowerBound..<nonMacBranch.lowerBound])
        let nonMacSource = String(source[nonMacBranch.upperBound..<macEnd.lowerBound])

        let geometry = try #require(macSource.range(of: "GeometryReader { proxy in"))
        let availableWidth = try #require(
            macSource.range(of: "min(max(proxy.size.width - 48, 0), 720)")
        )
        let explicitWidth = try #require(
            macSource.range(of: ".frame(width: min(max(proxy.size.width - 48, 0), 720))")
        )
        let centeredFrame = try #require(
            macSource.range(of: ".frame(maxWidth: .infinity, maxHeight: .infinity)")
        )
        #expect(geometry.lowerBound < availableWidth.lowerBound)
        #expect(geometry.lowerBound < explicitWidth.lowerBound)
        #expect(explicitWidth.lowerBound < centeredFrame.lowerBound)
        #expect(nonMacSource.trimmingCharacters(in: .whitespacesAndNewlines) == "settingsForm")
    }

    @Test func macCreateProjectHasUsableMinimumSize() throws {
        let source = try source(named: "CreateProjectView.swift")
        #expect(source.contains("minWidth: 520"))
        #expect(source.contains("idealWidth: 620"))
        #expect(source.contains("minHeight: 560"))
    }

    @Test func projectPhotoActionsAdaptToNarrowWidth() throws {
        let source = try source(named: "ProjectPhotoPicker.swift")
        let macBranch = try #require(source.range(of: "#if os(macOS)"))
        let nonMacBranch = try #require(
            source.range(of: "#else", range: macBranch.upperBound..<source.endIndex)
        )
        let macSource = String(source[macBranch.lowerBound..<nonMacBranch.lowerBound])
        let nonMacSource = String(source[nonMacBranch.upperBound...])

        #expect(macSource.contains("ViewThatFits"))
        #expect(macSource.contains("HStack"))
        #expect(macSource.contains("VStack"))
        #expect(!nonMacSource.contains("ViewThatFits"))

        let photoPicker = try #require(nonMacSource.range(of: "PhotosPicker(selection: $pickerItem"))
        let camera = try #require(nonMacSource.range(of: "UIImagePickerController.isSourceTypeAvailable"))
        let spacer = try #require(nonMacSource.range(of: "Spacer()"))
        let remove = try #require(nonMacSource.range(of: "Button(role: .destructive)"))
        #expect(photoPicker.lowerBound < camera.lowerBound)
        #expect(camera.lowerBound < spacer.lowerBound)
        #expect(spacer.lowerBound < remove.lowerBound)
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
