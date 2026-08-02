import Testing

@Suite struct PatternSystemAppearanceContractTests {
    @Test func monitorObservesTheActualPlatformAppearanceWithoutTimeHeuristics() throws {
        let source = try readRepositoryFile(
            "KnitNote/Patterns/PatternSystemAppearanceMonitor.swift"
        )

        #expect(source.contains("@Published private(set) var appearance"))
        #expect(source.contains("func start()"))
        #expect(source.contains("func refresh()"))
        #expect(source.contains("func stop()"))
        #expect(source.contains("UIApplication.didBecomeActiveNotification"))
        #expect(source.contains("connectedScenes"))
        #expect(source.contains("screen.traitCollection.userInterfaceStyle"))
        #expect(source.contains("PatternSystemAppearanceChangeProbe"))
        #expect(source.contains("traitCollectionDidChange"))
        #expect(source.contains("NSApp.observe(\\.effectiveAppearance"))
        #expect(!source.contains("Calendar"))
        #expect(!source.contains("Date()"))
    }
}
