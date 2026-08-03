import XCTest

final class MacYarnEditorAccessibilityUITests: XCTestCase {
    @MainActor
    func testCreateYarnFieldsExposeFullEnglishAccessibilityContract() {
        let app = launchFixture(language: .english)
        openManualCreateYarn(in: app, createYarnLabel: "Add Yarn", addManuallyLabelPrefix: "Add Manually")

        assertCreateYarnFields(
            in: app,
            createYarnLabel: "Add Yarn",
            expectedLabels: [
                "macYarnEditor.name": "Name",
                "macYarnEditor.brand": "Brand",
                "macYarnEditor.needleLower": "Knitting Needle, From",
                "macYarnEditor.needleUpper": "Knitting Needle, To",
                "macYarnEditor.hookLower": "Crochet Hook, From",
                "macYarnEditor.hookUpper": "Crochet Hook, To",
                "macYarnEditor.linkedProjects": "Linked Projects",
            ]
        )
    }

    @MainActor
    func testCreateYarnFieldsExposeFullTraditionalChineseAccessibilityContract() {
        let app = launchFixture(language: .traditionalChinese)
        openManualCreateYarn(in: app, createYarnLabel: "新增毛線", addManuallyLabelPrefix: "手動新增")

        assertCreateYarnFields(
            in: app,
            createYarnLabel: "新增毛線",
            expectedLabels: [
                "macYarnEditor.name": "名稱",
                "macYarnEditor.brand": "品牌",
                "macYarnEditor.needleLower": "建議棒針，最小",
                "macYarnEditor.needleUpper": "建議棒針，最大",
                "macYarnEditor.hookLower": "建議鉤針，最小",
                "macYarnEditor.hookUpper": "建議鉤針，最大",
                "macYarnEditor.linkedProjects": "關聯作品",
            ]
        )
    }

    @MainActor
    func testEditYarnControlsExposeEnglishAccessibilityContract() {
        let app = launchFixture(language: .english)
        openFixtureYarnForEditing(
            in: app,
            yarnName: "Cloud Wool",
            editLabel: "Edit Yarn"
        )
        assertEditYarnControls(
            in: app,
            scanLabel: "Scan Yarn Label",
            labelPhotosLabel: "Yarn Label Photos",
            photoImageLabel: "Yarn photo",
            photoButtonLabel: "Replace Photo"
        )
    }

    @MainActor
    func testEditYarnControlsExposeTraditionalChineseAccessibilityContract() {
        let app = launchFixture(language: .traditionalChinese)
        openFixtureYarnForEditing(
            in: app,
            yarnName: "雲霧羊毛",
            editLabel: "編輯毛線"
        )
        assertEditYarnControls(
            in: app,
            scanLabel: "掃描毛線標籤",
            labelPhotosLabel: "毛線標籤照片",
            photoImageLabel: "毛線照片",
            photoButtonLabel: "更換照片"
        )
    }

    @MainActor
    private func launchFixture(language: FixtureLanguage) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.phillon.KnitNote")
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", language.appleLanguagesArgument,
            "-AppleLocale", language.appleLocaleArgument,
            "-storeScreenshotMode", "YES",
            "-storeScreenshotScene", "yarn",
            "-storeScreenshotLanguage", language.screenshotArgument,
            "-storeScreenshotToken", "MacYarnEditorAccessibilityUITests-\(language.screenshotArgument)",
        ]
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func openManualCreateYarn(
        in app: XCUIApplication,
        createYarnLabel: String,
        addManuallyLabelPrefix: String
    ) {
        let createYarn = app.toolbars.buttons[createYarnLabel]
        XCTAssertTrue(createYarn.waitForExistence(timeout: 5))
        createYarn.click()

        let addManually = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", addManuallyLabelPrefix)
        ).firstMatch
        XCTAssertTrue(addManually.waitForExistence(timeout: 5))
        addManually.click()
    }

    @MainActor
    private func assertCreateYarnFields(
        in app: XCUIApplication,
        createYarnLabel: String,
        expectedLabels: [String: String]
    ) {
        for (identifier, expectedLabel) in expectedLabels {
            let element = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(createYarnLabel): \(identifier)")
            XCTAssertFalse(element.frame.isEmpty, "\(createYarnLabel): \(identifier)")
            XCTAssertEqual(element.label, expectedLabel, "\(createYarnLabel): \(identifier)")
        }
    }

    @MainActor
    private func openFixtureYarnForEditing(
        in app: XCUIApplication,
        yarnName: String,
        editLabel: String
    ) {
        let yarnCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", yarnName))
            .firstMatch
        XCTAssertTrue(yarnCard.waitForExistence(timeout: 5), yarnName)
        yarnCard.click()

        let edit = app.toolbars.buttons[editLabel]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), editLabel)
        edit.click()
    }

    @MainActor
    private func assertEditYarnControls(
        in app: XCUIApplication,
        scanLabel: String,
        labelPhotosLabel: String,
        photoImageLabel: String,
        photoButtonLabel: String
    ) {
        let scan = app.descendants(matching: .any)["macYarnEditor.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5), "macYarnEditor.scan")
        XCTAssertFalse(scan.frame.isEmpty, "macYarnEditor.scan")
        XCTAssertEqual(scan.label, scanLabel, "macYarnEditor.scan")

        let labelPhotos = app.descendants(matching: .any)["macYarnEditor.labelPhotos"]
        XCTAssertTrue(labelPhotos.waitForExistence(timeout: 5), "macYarnEditor.labelPhotos")
        XCTAssertFalse(labelPhotos.frame.isEmpty, "macYarnEditor.labelPhotos")
        XCTAssertEqual(labelPhotos.label, labelPhotosLabel, "macYarnEditor.labelPhotos")

        let photo = app.images["macYarnEditor.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "macYarnEditor.photo")
        XCTAssertFalse(photo.frame.isEmpty, "macYarnEditor.photo")
        XCTAssertEqual(photo.label, photoImageLabel, "macYarnEditor.photo")

        let replacePhoto = app.buttons[photoButtonLabel]
        XCTAssertTrue(replacePhoto.waitForExistence(timeout: 5), photoButtonLabel)
        XCTAssertFalse(replacePhoto.frame.isEmpty, photoButtonLabel)
    }

    private enum FixtureLanguage {
        case english
        case traditionalChinese

        var screenshotArgument: String {
            switch self {
            case .english: "en"
            case .traditionalChinese: "zh-Hant"
            }
        }

        var appleLanguagesArgument: String {
            switch self {
            case .english: "(en)"
            case .traditionalChinese: "(zh-Hant)"
            }
        }

        var appleLocaleArgument: String {
            switch self {
            case .english: "en_US"
            case .traditionalChinese: "zh_Hant_TW"
            }
        }
    }
}
