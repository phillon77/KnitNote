import XCTest

final class MacYarnEditorAccessibilityUITests: XCTestCase {
    @MainActor
    func testYarnRangeInputsExposeDistinctEnglishAccessibilityLabels() {
        assertRangeLabels(
            languageArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            createYarnLabel: "Add Yarn",
            addManuallyLabelPrefix: "Add Manually",
            expectedLabels: [
                "macYarnEditor.needleLower": "Knitting Needle, From",
                "macYarnEditor.needleUpper": "Knitting Needle, To",
                "macYarnEditor.hookLower": "Crochet Hook, From",
                "macYarnEditor.hookUpper": "Crochet Hook, To",
            ]
        )
    }

    @MainActor
    func testYarnRangeInputsExposeDistinctTraditionalChineseAccessibilityLabels() {
        assertRangeLabels(
            languageArguments: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_Hant_TW"],
            createYarnLabel: "新增毛線",
            addManuallyLabelPrefix: "手動新增",
            expectedLabels: [
                "macYarnEditor.needleLower": "建議棒針，最小",
                "macYarnEditor.needleUpper": "建議棒針，最大",
                "macYarnEditor.hookLower": "建議鉤針，最小",
                "macYarnEditor.hookUpper": "建議鉤針，最大",
            ]
        )
    }

    @MainActor
    private func assertRangeLabels(
        languageArguments: [String],
        createYarnLabel: String,
        addManuallyLabelPrefix: String,
        expectedLabels: [String: String]
    ) {
        let app = XCUIApplication(bundleIdentifier: "com.phillon.KnitNote")
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-languageSelection", "system",
        ]
        app.launchArguments += languageArguments
        app.launch()

        app.activate()

        let yarnLibrary = app.radioButtons["shippingbox"]
        XCTAssertTrue(yarnLibrary.waitForExistence(timeout: 5))
        yarnLibrary.click()

        let createYarn = app.toolbars.buttons[createYarnLabel]
        XCTAssertTrue(createYarn.waitForExistence(timeout: 5))
        createYarn.click()

        let addManually = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", addManuallyLabelPrefix)
        ).firstMatch
        XCTAssertTrue(addManually.waitForExistence(timeout: 5))
        addManually.click()

        for (identifier, expectedLabel) in expectedLabels {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5), identifier)
            XCTAssertFalse(field.frame.isEmpty, identifier)
            XCTAssertEqual(field.label, expectedLabel, identifier)
        }
    }
}
