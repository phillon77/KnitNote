import Foundation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import KnitNote

@Suite struct MacFormLayoutSmokeTests {
    @MainActor
    @Test func macCanHostTheSharedAccessStatusAndRestoreContent() {
        let coordinator = EntitlementCoordinator.configured(screenshotMode: true)
        let host = NSHostingView(rootView: AccessSettingsContent(onShowUnlock: {})
            .environmentObject(coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
    }

    @MainActor
    @Test func macCanHostJournalDetailActionsWithShareAvailableInReadOnlyHistory() {
        var shareCount = 0
        let host = NSHostingView(rootView: MacJournalDetailActionBar(
            isCompleted: true,
            onShare: { shareCount += 1 },
            onEdit: {},
            onDelete: {}
        ))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 460, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height >= 44)
        #expect(shareCount == 0)
    }

    @Test func macFormLayoutSourcesExposeTheRequiredAdaptiveStructure() throws {
        let settings = try source(named: "SettingsView.swift", in: "Settings")
        let project = try source(named: "CreateProjectView.swift", in: "Projects")
        let photoPicker = try source(named: "ProjectPhotoPicker.swift", in: "Projects")

        #expect(settings.contains("#if os(macOS)"))
        #expect(settings.contains("private var macSettingsContent: some View"))
        #expect(settings.contains("MacSettingsLayout.contentMaximumWidth"))
        #expect(settings.contains("MacSettingsLayout.outerPadding"))
        #expect(settings.contains("MacSettingsSection(title: \"settings.general\")"))
        #expect(settings.contains("MacSettingsSection(title: \"calculator.tools.title\")"))
        #expect(settings.contains("MacSettingsSection(title: \"settings.data\")"))
        #expect(settings.contains("MacSettingsSection(title: \"settings.about\")"))
        #expect(project.contains("minWidth: 520"))
        #expect(project.contains("idealWidth: 620"))
        #expect(project.contains("minHeight: 560"))
        #expect(photoPicker.contains("ViewThatFits"))

        let macBranch = try #require(project.range(of: "#if os(macOS)"))
        let nonMacBranch = try #require(
            project.range(of: "#else", range: macBranch.upperBound..<project.endIndex)
        )
        let macProject = String(project[macBranch.lowerBound..<nonMacBranch.lowerBound])
        let nonMacProject = String(project[nonMacBranch.upperBound...])

        #expect(macProject.contains("ScrollView"))
        #expect(macProject.contains("VStack(alignment: .leading, spacing: 20)"))
        #expect(macProject.contains(".frame(maxWidth: 720)"))
        #expect(!macProject.contains("Form"))
        #expect(nonMacProject.contains("Form"))
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
