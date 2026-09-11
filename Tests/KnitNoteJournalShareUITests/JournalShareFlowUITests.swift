import XCTest

final class JournalShareFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    private func launchSharePreview() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-storeScreenshotMode", "YES",
            "-storeScreenshotScene", "projects",
            "-storeScreenshotLanguage", "en",
            "-storeScreenshotToken", "JournalShareFlowUITests"
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["storeScreenshot.ready"].waitForExistence(timeout: 10))
        app.staticTexts["Cloud Shawl"].firstMatch.tap()
        let journal = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "First pattern section complete")).firstMatch
        scrollUntilHittable(journal)
        journal.tap()
        let openShare = app.buttons["journalShare.open"]
        XCTAssertTrue(openShare.waitForExistence(timeout: 5))
        openShare.tap()
        XCTAssertTrue(app.otherElements["journalShare.preview"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testControlsFormatsMetadataTextCopyAndSaveAreReachable() {
        launchSharePreview()
        XCTAssertTrue(app.segmentedControls["journalShare.format"].exists)
        app.segmentedControls["journalShare.format"].buttons.element(boundBy: 1).tap()
        app.segmentedControls["journalShare.format"].buttons.element(boundBy: 0).tap()

        for identifier in ["journalShare.showProject", "journalShare.showDate", "journalShare.showCaption", "journalShare.showBrand"] {
            let toggle = app.switches[identifier]
            XCTAssertTrue(toggle.exists)
            toggle.tap()
            toggle.tap()
        }

        let text = app.textFields["journalShare.text"]
        XCTAssertTrue(text.exists)
        text.tap()
        text.typeText(" shared")
        app.otherElements["journalShare.preview"].tap()
        app.switches["journalShare.hashtag"].tap()
        scrollUntilHittable(app.buttons["journalShare.copy"])
        XCTAssertTrue(app.buttons["journalShare.copy"].isEnabled)
        XCTAssertGreaterThanOrEqual(app.buttons["journalShare.copy"].frame.height, 43.5)
        app.buttons["journalShare.copy"].tap()
        XCTAssertTrue(app.staticTexts["journalShare.copyFeedback"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["journalShare.save"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons["journalShare.save"].frame.height, 43.5)
    }

    @MainActor
    func testSystemShareSheetCanBeCancelledAndPreviewRemains() {
        launchSharePreview()
        let share = app.buttons["journalShare.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        XCTAssertTrue(share.isEnabled)
        share.tap()
        let activity = app.otherElements["ActivityListView"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.swipeDown(velocity: .fast)
        if activity.exists { activity.swipeDown(velocity: .fast) }
        XCTAssertTrue(activity.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["journalShare.preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["journalShare.share"].isEnabled)
    }

    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, limit: Int = 8) {
        for _ in 0..<limit where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
}
