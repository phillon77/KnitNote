import Foundation
import Testing

@Suite("Even stitch adjustment view contracts")
struct EvenStitchAdjustmentViewContractTests {
    @Test func adjustmentToolSwitchesBetweenOneRowAndAcrossRows() throws {
        let host = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")
        let rows = try appSource("KnitNote/Calculators/RowIntervalAdjustmentView.swift")

        #expect(host.contains("calculator.adjustment.mode.oneRow"))
        #expect(host.contains("calculator.adjustment.mode.acrossRows"))
        #expect(host.contains("RowIntervalAdjustmentView()"))
        #expect(host.contains(".pickerStyle(.segmented)"))
        #expect(rows.contains("RowIntervalAdjustmentCalculator.calculate"))
        #expect(rows.contains("calculator.adjustment.rows.details.show"))
        #expect(rows.contains("LazyVStack"))
        #expect(rows.contains("accessibilityLabel"))
    }

    @Test func crossRowFormFormatsLocalizedAccessibleResultsWithoutDuplicatingRows() throws {
        let rows = try appSource("KnitNote/Calculators/RowIntervalAdjustmentView.swift")

        #expect(rows.contains("result.operation, result.style"))
        #expect(rows.contains(".increase, .singleSide"))
        #expect(rows.contains(".decrease, .bothSides"))
        #expect(rows.contains("result.minimumInterval == result.maximumInterval"))
        #expect(rows.contains("calculator.adjustment.rows.interval.exact.format"))
        #expect(rows.contains("calculator.adjustment.rows.interval.range.format"))
        #expect(rows.contains("String.localizedStringWithFormat"))
        #expect(rows.contains(".accessibilityElement(children: .ignore)"))
        #expect(rows.contains("ForEach(adjustment.adjustmentRows.indices, id: \\.self)"))
        #expect(!rows.contains(".joined(separator:"))
        #expect(!rows.contains("Array(adjustment.adjustmentRows.enumerated())"))
    }

    @Test func crossRowSummaryFormatsIntervalBeforeEventCount() throws {
        let rows = try appSource("KnitNote/Calculators/RowIntervalAdjustmentView.swift")

        #expect(sourceContains(
            rows,
            pattern: #"return\s+String\.localizedStringWithFormat\(\s*format,\s*interval,\s*result\.eventCount\s*\)"#
        ))
    }

    @Test func crossRowExactIntervalUsesDedicatedEveryRowCopyForOneRow() throws {
        let rows = try appSource("KnitNote/Calculators/RowIntervalAdjustmentView.swift")

        #expect(rows.contains("result.minimumInterval == 1"))
        #expect(rows.contains("result.maximumInterval == 1"))
        #expect(rows.contains("calculator.adjustment.rows.interval.everyRow"))
        #expect(sourceContains(
            rows,
            pattern: #"if\s+result\.minimumInterval\s*==\s*1\s*,\s*result\.maximumInterval\s*==\s*1\s*\{[\s\S]*?calculator\.adjustment\.rows\.interval\.everyRow[\s\S]*?\}\s*if\s+result\.minimumInterval\s*==\s*result\.maximumInterval"#
        ))
    }

    @Test func crossRowSuccessCardPresentsTheIntervalOnlyThroughItsSummary() throws {
        let rows = try appSource("KnitNote/Calculators/RowIntervalAdjustmentView.swift")

        #expect(rows.contains("let summary = summaryText(adjustment)"))
        #expect(rows.contains(".accessibilityLabel(Text(verbatim: summary))"))
        #expect(!rows.contains("Text(verbatim: interval)"))
        #expect(!rows.contains("accessibilitySummary(summary: summary, interval: interval)"))
        #expect(!rows.contains("private func accessibilitySummary(summary:"))
    }

    @Test func crossRowStylePickerAlwaysUsesAnUntruncatedMenu() throws {
        let rows = try appSource("KnitNote/Calculators/RowIntervalAdjustmentView.swift")

        #expect(!rows.contains("dynamicTypeSize"))
        #expect(sourceContains(
            rows,
            pattern: #"Picker\("calculator\.adjustment\.rows\.operation", selection: \$operation\)[\s\S]*?\.pickerStyle\(\.segmented\)"#
        ))
        #expect(sourceContains(
            rows,
            pattern: #"Picker\("calculator\.adjustment\.rows\.style", selection: \$style\)[\s\S]*?\.pickerStyle\(\.menu\)"#
        ))
        #expect(!sourceContains(
            rows,
            pattern: #"Picker\("calculator\.adjustment\.rows\.style", selection: \$style\)[\s\S]*?\.pickerStyle\(\.segmented\)"#
        ))
    }

    @Test func crossRowFailureMessageIsComputedOnceAndKeepsAnInvalidCountFallback() throws {
        let rows = try appSource("KnitNote/Calculators/RowIntervalAdjustmentView.swift")

        #expect(rows.contains("let message = failureText(failure)"))
        #expect(rows.contains("Text(verbatim: message)"))
        #expect(rows.contains("accessibilityLabel(Text(verbatim: message))"))
        #expect(rows.components(separatedBy: "failureText(failure)").count == 2)
        #expect(rows.contains("case .invalidCounts:"))
        #expect(rows.contains("calculator.adjustment.validation.positiveInteger"))
    }

    @Test func evenAdjustmentViewUsesCoreAndApprovedLayout() throws {
        let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")

        #expect(source.contains("EvenStitchAdjustmentCalculator.calculate"))
        #expect(source.contains("@State private var reservesEdgeStitches = true"))
        #expect(source.contains("DisclosureGroup"))
        #expect(source.contains("WatercolorCard"))
        #expect(source.contains("frame(maxWidth: 620)"))
        #expect(source.contains("keyboardType(.numberPad)"))
        #expect(source.contains("calculator.adjustment.validation.positiveInteger"))
    }

    @Test func inputParsingSeparatesInvalidValuesFromSupportedLimitFailures() throws {
        let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")

        #expect(source.contains("EvenStitchAdjustmentInputParser.parse"))
        #expect(source.contains("return .failure(.exceedsSupportedLimit)"))
        #expect(!source.contains(".intValue"))
        #expect(!source.contains("NSDecimalNumber"))
    }

    @Test func fieldsValidateIndependentlyWhileTheLimitUsesItsOwnFailureCard() throws {
        let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")

        #expect(source.contains("case .empty, .invalid:"))
        #expect(source.contains("case .valid, .exceedsSupportedLimit:"))
        #expect(source.contains("calculator.adjustment.failure.exceedsSupportedLimit.format"))
        #expect(source.contains("@State private var reservesEdgeStitches = true"))
        #expect(source.contains("Toggle("))
    }

    @Test func summaryAndStepsKeepVoiceOverFocusSeparate() throws {
        let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")

        #expect(source.contains("accessibilitySummary("))
        #expect(source.contains("calculator.adjustment.accessibility.summary.full.format"))
        #expect(source.contains("calculator.adjustment.accessibility.summary.interval.format"))
        #expect(source.contains("calculator.adjustment.accessibility.summary.edge.format"))
        #expect(!source.contains(".joined(separator:"))
        #expect(source.contains(".accessibilityElement(children: .ignore)"))
        #expect(source.contains("DisclosureGroup(\"calculator.adjustment.steps.show\")"))
        #expect(!source.contains(".accessibilityElement(children: .combine)"))
    }

    @Test func intervalDistinguishesSingleRangesAndAdjacentDecreases() throws {
        let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")

        #expect(source.contains("minimum == maximum"))
        #expect(source.contains("minimum == 0"))
        #expect(source.contains("calculator.adjustment.interval.decrease.adjacent"))
        #expect(source.contains("calculator.adjustment.interval.increase.single.format"))
        #expect(source.contains("calculator.adjustment.interval.decrease.single.format"))
        #expect(source.contains("intervalRangeText(minimum: minimum, maximum: maximum)"))
    }

    @Test func EnglishCountCopyBranchesForEveryPossibleSingularResult() throws {
        let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")

        #expect(source.contains("adjustmentCount == 1"))
        #expect(source.contains("minimum == 1"))
        #expect(source.contains("case .knit(1):"))
        #expect(source.contains("calculator.adjustment.summary.increase.singular"))
        #expect(source.contains("calculator.adjustment.summary.decrease.singular"))
        #expect(source.contains("calculator.adjustment.interval.increase.singular"))
        #expect(source.contains("calculator.adjustment.interval.decrease.singular"))
        #expect(source.contains("calculator.adjustment.step.knit.singular"))
    }

    @Test func intervalUsesOneLocalizedRangeArgument() throws {
        let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")

        #expect(source.contains("private func intervalRangeText"))
        #expect(source.contains("calculator.adjustment.interval.range.format"))
        #expect(source.contains("String.localizedStringWithFormat(format, range)"))
        #expect(!source.contains("String.localizedStringWithFormat(format, minimum, maximum)"))
    }

    @Test func stepsUseStructuredLazyRenderingWithoutCopyingTheSequence() throws {
        let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")

        #expect(source.contains("LazyVStack"))
        #expect(source.contains("ForEach(adjustment.steps.indices, id: \\.self)"))
        #expect(source.contains("stepText(adjustment.steps[index])"))
        #expect(!source.contains("Array(adjustment.steps.enumerated())"))
        #expect(source.contains("#if os(iOS)"))
        #expect(source.contains("keyboardType(.numberPad)"))
    }

    @Test func calculatorMenuAndEntriesExposeBothCalculators() throws {
        let menu = try appSource("KnitNote/Calculators/KnittingCalculatorsView.swift")
        let settings = try appSource("KnitNote/Settings/SettingsView.swift")
        let project = try appSource("KnitNote/Projects/ProjectDetailView.swift")

        #expect(menu.contains("GaugeCalculatorView()"))
        #expect(menu.contains("EvenStitchAdjustmentCalculatorView()"))
        #expect(menu.contains("WatercolorCard"))
        #expect(menu.contains("frame(maxWidth: 620)"))
        #expect(settings.contains("GaugeCalculatorView()"))
        #expect(settings.contains("EvenStitchAdjustmentCalculatorView()"))
        #expect(project.contains("KnittingCalculatorsView()"))
        #expect(!project.contains("GaugeCalculatorView()"))
        #expect(project.contains("Label(\"calculator.tools.title\""))

        let counters = try #require(project.range(of: "CounterSelectorGrid("))
        let tools = try #require(project.range(of: "KnittingCalculatorsView()"))
        let notes = try #require(project.range(of: "\"notes.edit\""))
        #expect(counters.lowerBound < tools.lowerBound && tools.lowerBound < notes.lowerBound)
    }

    @Test func projectNoteAndPatternActionsMatchTheFullWidthCalculatorCardStyle() throws {
        let project = try appSource("KnitNote/Projects/ProjectDetailView.swift")

        #expect(project.contains("projectActionCard("))
        #expect(project.contains("\"notes.edit\", icon: \"note.text\""))
        #expect(project.contains("\"patterns.open\", icon: \"doc.text.image\""))
        #expect(project.contains("private func projectActionCard"))
        #expect(project.contains("Label(title, systemImage: icon)"))
        #expect(project.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(project.contains(".buttonStyle(.plain)"))
        #expect(!project.contains("supportingButton("))
        #expect(!project.contains(".labelStyle(.iconOnly)"))

        let tools = try #require(project.range(of: "KnittingCalculatorsView()"))
        let notes = try #require(project.range(of: "\"notes.edit\"", range: tools.upperBound..<project.endIndex))
        let patterns = try #require(project.range(of: "\"patterns.open\"", range: notes.upperBound..<project.endIndex))
        let journal = try #require(project.range(of: "ProjectJournalSection(", range: patterns.upperBound..<project.endIndex))
        #expect(tools.lowerBound < notes.lowerBound)
        #expect(notes.lowerBound < patterns.lowerBound)
        #expect(patterns.lowerBound < journal.lowerBound)
    }
}

private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func sourceContains(_ source: String, pattern: String) -> Bool {
    source.range(of: pattern, options: .regularExpression) != nil
}
