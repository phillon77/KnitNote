import XCTest
@testable import KnittingCalculator
import KnittingCalculatorCore

final class CalculatorShareTextTests: XCTestCase {
    private let supportedLocales = [
        "en", "zh-Hant", "zh-Hans", "de", "fr", "ja", "ko",
        "nl", "nb", "sv", "fi", "da", "el",
    ]
    private let expectedAttributions = [
        "en": "Calculated with Knitting Calculator.",
        "zh-Hant": "由編織計算器計算。",
        "zh-Hans": "由编织计算器计算。",
        "de": "Berechnet mit Strickrechner.",
        "fr": "Calculé avec le Calculateur de tricot.",
        "ja": "編み物計算機で計算しました。",
        "ko": "뜨개질 계산기로 계산했습니다.",
        "nl": "Berekend met Breicalculator.",
        "nb": "Beregnet med Strikkekalkulator.",
        "sv": "Beräknat med Stickkalkylator.",
        "fi": "Laskettu Neulelaskurilla.",
        "da": "Beregnet med Strikkeberegner.",
        "el": "Υπολογίστηκε με την Αριθμομηχανή Πλεξίματος.",
    ]

    func testProductLinksUseAssignedAppStoreIDs() {
        XCTAssertEqual(
            CalculatorProductLinks.freeApp.absoluteString,
            "https://apps.apple.com/app/id6795877892"
        )
        XCTAssertEqual(
            KnitNoteLinkRouter.storeURL.absoluteString,
            "https://apps.apple.com/app/id6793023054"
        )
    }

    func testGaugeShareContainsInputsResultAttributionAndFreeAppURL() throws {
        let result = try XCTUnwrap(
            GaugeCalculator.calculate(
                .init(sampleLength: 10, sampleCount: 20, targetLength: 40)
            )
        )

        let text = CalculatorShareText.gauge(
            .init(
                unit: .centimeters,
                sampleLength: 10,
                sampleCount: 20,
                targetLength: 40,
                result: result,
                rows: nil
            ),
            locale: Locale(identifier: "zh-Hant")
        )

        XCTAssertTrue(text.contains("10"))
        XCTAssertTrue(text.contains("80"))
        XCTAssertTrue(text.contains("由編織計算器計算"))
        XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString))
        XCTAssertFalse(text.contains("https://apps.apple.com/app/id6793023054"))
    }

    func testSimplifiedChineseGaugeShareUsesNaturalDensityWording() throws {
        let stitchResult = try XCTUnwrap(
            GaugeCalculator.calculate(
                .init(sampleLength: 10, sampleCount: 20, targetLength: 40)
            )
        )
        let rowResult = try XCTUnwrap(
            GaugeCalculator.calculate(
                .init(sampleLength: 10, sampleCount: 30, targetLength: 40)
            )
        )

        let text = CalculatorShareText.gauge(
            .init(
                unit: .centimeters,
                sampleLength: 10,
                sampleCount: 20,
                targetLength: 40,
                result: stitchResult,
                rows: .init(
                    sampleLength: 10,
                    sampleCount: 30,
                    targetLength: 40,
                    result: rowResult
                )
            ),
            locale: Locale(identifier: "zh-Hans")
        )

        XCTAssertTrue(text.contains("针数密度：2 针／厘米。精确结果：80 针。建议：80 针。"))
        XCTAssertTrue(text.contains("行数密度：3 行／厘米。精确结果：120 行。建议：120 行。"))
        XCTAssertFalse(text.contains("每 2 针／厘米"))
        XCTAssertFalse(text.contains("每 3 行／厘米"))
    }

    func testOneRowShareIncludesEdgeChoiceAndCompleteSteps() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 20, target: 24, reservesEdgeStitches: true)
        )

        let text = CalculatorShareText.oneRow(
            .init(
                current: 20,
                target: 24,
                reservesEdgeStitches: true,
                result: result
            ),
            locale: Locale(identifier: "en")
        )

        XCTAssertTrue(text.contains("20"))
        XCTAssertTrue(text.contains("24"))
        XCTAssertTrue(text.contains("One edge stitch on each side"))
        XCTAssertTrue(text.contains("Increase 1 stitch"))
        XCTAssertTrue(text.contains("Calculated with Knitting Calculator"))
        XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString))
        XCTAssertFalse(text.contains("https://apps.apple.com/app/id6793023054"))
    }

    func testAcrossRowsShareIncludesIntervalAndAdjustmentRows() throws {
        let input = RowIntervalAdjustmentInput(
            totalRows: 8,
            totalStitches: 4,
            operation: .increase,
            style: .singleSide
        )
        let result = try RowIntervalAdjustmentCalculator.calculate(input)

        let text = CalculatorShareText.rowInterval(
            .init(input: input, result: result),
            locale: Locale(identifier: "zh-Hant")
        )

        XCTAssertTrue(text.contains("8"))
        XCTAssertTrue(text.contains("4"))
        XCTAssertTrue(text.contains("每 2 排"))
        XCTAssertTrue(text.contains("2、4、6、8"))
        XCTAssertTrue(text.contains("由編織計算器計算"))
        XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString))
        XCTAssertFalse(text.contains("https://apps.apple.com/app/id6793023054"))
    }

    func testBothSidesAcrossRowsShareIsNaturalForEverySupportedLocale() throws {
        let expectedResultLines = [
            "en": "2 adjustment events. Stitches per event: 2. Interval: Every 4 rows.",
            "zh-Hant": "共 2 次調整。每次調整針數：2。間隔：每 4 排。",
            "zh-Hans": "共 2 次调整。每次调整针数：2。间隔：每 4 行。",
            "de": "2 Anpassungsvorgänge. Maschen pro Vorgang: 2. Abstand: Alle 4 Reihen.",
            "fr": "2 opérations d’ajustement. Mailles par opération : 2. Intervalle : Tous les 4 rangs.",
            "ja": "調整は2回。1回あたりの目数：2。間隔：4段ごと。",
            "ko": "조정 2회. 회당 코 수: 2. 간격: 4단마다.",
            "nl": "2 aanpassingen. Steken per aanpassing: 2. Tussenruimte: Elke 4 toeren.",
            "nb": "2 justeringer. Masker per justering: 2. Intervall: Hver 4. rad.",
            "sv": "2 justeringar. Maskor per justering: 2. Intervall: Vart 4:e varv.",
            "fi": "2 säätökertaa. Silmukoita säätökertaa kohti: 2. Väli: Joka 4. kerros.",
            "da": "2 justeringer. Masker pr. justering: 2. Mellemrum: Hver 4. række.",
            "el": "2 ενέργειες προσαρμογής. Πόντοι ανά ενέργεια: 2. Διάστημα: Κάθε 4 σειρές.",
        ]
        let input = RowIntervalAdjustmentInput(
            totalRows: 8,
            totalStitches: 4,
            operation: .increase,
            style: .bothSides
        )
        let result = try RowIntervalAdjustmentCalculator.calculate(input)
        XCTAssertEqual(result.stitchesPerEvent, 2)

        for identifier in supportedLocales {
            let text = CalculatorShareText.rowInterval(
                .init(input: input, result: result),
                locale: Locale(identifier: identifier)
            )

            XCTAssertTrue(text.contains(expectedResultLines[identifier]!), identifier)
            XCTAssertTrue(text.contains(expectedAttributions[identifier]!), identifier)
            XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString), identifier)
        }
    }

    func testOneRowShareLocalizesAttributionAndInstructionsForEverySupportedLocale() throws {
        let expectedInstructions = [
            "en": "Increase 1 stitch",
            "zh-Hant": "加 1 針",
            "zh-Hans": "加 1 针",
            "de": "1 Masche zunehmen",
            "fr": "Augmenter d’1 maille",
            "ja": "1目増し目する",
            "ko": "1코 늘리기",
            "nl": "Meerder 1 steek",
            "nb": "Øk 1 maske",
            "sv": "Öka 1 maska",
            "fi": "Lisää 1 silmukka",
            "da": "Tag 1 maske ud",
            "el": "Αυξήστε κατά 1 πόντο",
        ]
        let result = try XCTUnwrap(
            EvenStitchAdjustmentCalculator.calculate(
                .init(current: 20, target: 24, reservesEdgeStitches: true)
            )
        )

        for identifier in supportedLocales {
            let text = CalculatorShareText.oneRow(
                .init(
                    current: 20,
                    target: 24,
                    reservesEdgeStitches: true,
                    result: result
                ),
                locale: Locale(identifier: identifier)
            )

            XCTAssertTrue(text.contains(expectedAttributions[identifier]!), identifier)
            XCTAssertTrue(text.contains(expectedInstructions[identifier]!), identifier)
            XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString), identifier)
            XCTAssertFalse(text.contains("https://apps.apple.com/app/id6793023054"), identifier)
        }
    }
}
