import Testing
@testable import KnitNoteCore

@Suite struct MacSettingsLayoutTests {
    @Test func approvedSingleColumnMetricsStayCompactAndReadable() {
        #expect(MacSettingsLayout.contentMaximumWidth == 560)
        #expect(MacSettingsLayout.outerPadding == 28)
        #expect(MacSettingsLayout.sectionSpacing == 16)
        #expect(MacSettingsLayout.minimumRowHeight == 44)
    }
}
