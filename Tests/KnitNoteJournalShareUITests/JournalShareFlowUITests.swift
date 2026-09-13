import XCTest

final class JournalShareFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    func testSettingsKeepsRestoreReachable() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Use the real root rather than the screenshot-only project scene.
        // Do not initiate a real StoreKit restore or change existing user data.
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_Hant_TW",
            "-languageSelection", "zh-Hant"
        ]
        app.launch()
        let settings = app.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let status = app.staticTexts["access.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(status.label.hasPrefix("access."))
        let restore = app.buttons["access.restore"]
        XCTAssertTrue(restore.isHittable)
        XCTAssertTrue(restore.isEnabled)
        if ["已永久解鎖", "舊版付費用戶"].contains(status.label) {
            XCTAssertFalse(app.buttons["access.purchase"].exists)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "access-settings-zh-Hant"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchSharePreview(
        language: String = "en",
        locale: String = "en_US"
    ) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "-storeScreenshotMode", "YES",
            "-storeScreenshotScene", "projects",
            "-storeScreenshotLanguage", language,
            "-storeScreenshotToken", "JournalShareFlowUITests-\(language)"
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
    func testCompletedProjectJournalRemainsShareableAndReadOnly() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-storeScreenshotMode", "YES",
            "-storeScreenshotScene", "projects",
            "-storeScreenshotLanguage", "en",
            "-storeScreenshotToken", "JournalShareFlowUITests-completed"
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["storeScreenshot.ready"].waitForExistence(timeout: 10))
        app.staticTexts["Cloud Shawl"].firstMatch.tap()

        let editProject = app.buttons["Edit Project"]
        XCTAssertTrue(editProject.waitForExistence(timeout: 5))
        editProject.tap()
        let markCompleted = app.buttons["Mark as Completed"]
        scrollUntilHittable(markCompleted)
        markCompleted.tap()

        let journal = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "First pattern section complete")).firstMatch
        scrollUntilHittable(journal)
        journal.tap()
        XCTAssertTrue(app.buttons["journalShare.open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)

        app.buttons["journalShare.open"].tap()
        XCTAssertTrue(app.otherElements["journalShare.preview"].waitForExistence(timeout: 10))
        attachReadyPreview(named: "completed-project-normal")
    }

    @MainActor
    func testTraditionalChineseAccessibilityPreviewUsesReflowedFormatControls() {
        launchSharePreview(
            language: "zh-Hant",
            locale: "zh_Hant_TW"
        )
        XCTAssertFalse(app.segmentedControls["journalShare.format"].exists)
        let post = app.buttons["貼文 4:5"]
        let story = app.buttons["限時動態 9:16"]
        XCTAssertTrue(post.waitForExistence(timeout: 5))
        XCTAssertTrue(story.exists)
        XCTAssertTrue(post.isSelected)
        XCTAssertFalse(story.isSelected)

        story.tap()
        XCTAssertFalse(post.isSelected)
        XCTAssertTrue(story.isSelected)

        post.tap()
        XCTAssertTrue(post.isSelected)
        XCTAssertFalse(story.isSelected)
        attachReadyPreview(named: "zh-Hant-accessibility-xxxl")
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
    func testBothFormatsSaveToPhotosWithoutTerminatingApp() {
        for formatIndex in 0...1 {
            launchSharePreview()
            app.segmentedControls["journalShare.format"].buttons.element(boundBy: formatIndex).tap()
            let save = app.buttons["journalShare.save"]
            scrollUntilHittable(save)
            let enabled = NSPredicate(format: "enabled == true")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: save)], timeout: 10), .completed)
            save.tap()

            let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if permission.waitForExistence(timeout: 3) {
                let allow = permission.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@ OR label == %@", "Allow", "允許")).firstMatch
                XCTAssertTrue(allow.exists, "Expected the Photos add-only permission prompt")
                allow.tap()
            }

            XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(save.isEnabled)
            attachReadyPreview(named: "saved-to-photos-format-\(formatIndex)")
        }
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

    @MainActor
    private func attachReadyPreview(named name: String) {
        XCTAssertTrue(app.otherElements["journalShare.preview"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
