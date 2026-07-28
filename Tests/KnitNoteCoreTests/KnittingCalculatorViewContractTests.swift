import Foundation
import Testing

@Suite struct KnittingCalculatorViewContractTests {
    @Test func gaugeScreenShowsExactRecommendationAndOptionalRows() throws {
        let source = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
        #expect(source.contains("GaugeCalculator.calculate"))
        #expect(source.contains("result.exactCount"))
        #expect(source.contains("result.recommendedCount"))
        #expect(source.contains("rowsWereStarted"))
        #expect(source.contains("GaugeCalculator.convertLength"))
        #expect(source.contains("calculator.gauge.patternCaution"))
        #expect(source.contains("accessibilityElement(children: .combine)"))
    }

    @Test func gaugeScreenExposesItsCurrentSnapshotToAConsumer() throws {
        let source = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
        #expect(source.contains("onShareSnapshotChange"))
        #expect(source.contains("onShareSnapshotChange(shareSnapshot)"))
        #expect(source.contains("onShareSnapshotChange(newValue)"))
    }

    @Test func adjustmentScreensKeepBothModesAndNeutralSteps() throws {
        let root = try freeAppSource("Adjustment/AdjustmentCalculatorScreen.swift")
        let oneRow = try freeAppSource("Adjustment/OneRowAdjustmentView.swift")
        let rows = try freeAppSource("Adjustment/RowIntervalAdjustmentView.swift")
        #expect(root.contains("adjustment.mode.oneRow"))
        #expect(root.contains("adjustment.mode.acrossRows"))
        #expect(oneRow.contains("reservesEdgeStitches"))
        #expect(oneRow.contains("DisclosureGroup"))
        #expect(oneRow.contains("EvenStitchAdjustmentCalculator.calculate"))
        #expect(rows.contains("RowIntervalAdjustmentCalculator.calculate"))
        #expect(rows.contains("RowIntervalAdjustmentStyle.bothSides"))
        #expect(!oneRow.contains("Knit "))
    }

    @Test func validCalculatorResultsExposeAccessibleCopyAndSystemShareActions() throws {
        let gauge = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
        let oneRow = try freeAppSource("Adjustment/OneRowAdjustmentView.swift")
        let rows = try freeAppSource("Adjustment/RowIntervalAdjustmentView.swift")
        let actions = try freeAppSource("Components/CalculatorResultActions.swift")

        #expect(gauge.contains("CalculatorShareText.gauge"))
        #expect(oneRow.contains("CalculatorShareText.oneRow"))
        #expect(rows.contains("CalculatorShareText.rowInterval"))
        #expect(actions.contains("ShareLink(item: text)"))
        #expect(actions.contains("UIPasteboard.general.string = text"))
        #expect(actions.contains("accessibilityLabel"))
        #expect(actions.contains("minHeight: 44"))
        #expect(!actions.contains("recordValidCalculation"))
    }

    @Test func adjustmentResultActionsRemainOutsideCombinedSummaryAccessibilityElement() throws {
        let oneRow = try freeAppSource("Adjustment/OneRowAdjustmentView.swift")
        let rows = try freeAppSource("Adjustment/RowIntervalAdjustmentView.swift")

        #expect(resultSummaryKeepsActionsOutsideCombinedAccessibilityElement(in: oneRow))
        #expect(resultSummaryKeepsActionsOutsideCombinedAccessibilityElement(in: rows))
    }

    @Test func homeHasExactlyTwoToolDestinationsAndOnePromotionSlot() throws {
        let source = try freeAppSource("Home/CalculatorHomeView.swift")
        #expect(source.components(separatedBy: "NavigationLink").count - 1 == 2)
        #expect(source.contains("GaugeCalculatorScreen()"))
        #expect(source.contains("AdjustmentCalculatorScreen()"))
        #expect(source.components(separatedBy: "KnitNotePromotionCard").count - 1 == 1)
        #expect(source.contains("frame(maxWidth: 620)"))
    }

    @Test func toolScreensExposeSinglePageHelp() throws {
        let gauge = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
        let adjustment = try freeAppSource("Adjustment/AdjustmentCalculatorScreen.swift")
        #expect(gauge.contains("CalculatorHelpSheet(tool: .gauge)"))
        #expect(adjustment.contains("CalculatorHelpSheet(tool: .adjustment)"))
    }

    @Test func homeUsesLocalizedNavigationTitleAndNeutralVisibleReservedCard() throws {
        let home = try freeAppSource("Home/CalculatorHomeView.swift")
        let theme = try freeAppSource("Theme/CalculatorTheme.swift")

        #expect(home.contains(".navigationTitle(\"app.title\")"))
        #expect(!home.contains(".accessibilityHint"))
        #expect(theme.contains("Text(\"calculator.home.promotion.placeholder\")"))
    }

    private func resultSummaryKeepsActionsOutsideCombinedAccessibilityElement(
        in source: String
    ) -> Bool {
        guard let successfulStart = source.range(of: "private func successfulResultView"),
              let summaryStart = source.range(of: "private func resultSummaryView"),
              let failureStart = source.range(of: "private func failureView") else {
            return false
        }
        let successful = source[successfulStart.lowerBound..<summaryStart.lowerBound]
        let summary = source[summaryStart.lowerBound..<failureStart.lowerBound]
        return successful.contains("CalculatorResultActions(")
            && !successful.contains(".accessibilityElement(children: .combine)")
            && summary.contains(".accessibilityElement(children: .combine)")
            && !summary.contains("CalculatorResultActions(")
    }

    private func freeAppSource(_ path: String) throws -> String {
        try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "KnittingCalculator/" + path),
            encoding: .utf8
        )
    }
}
