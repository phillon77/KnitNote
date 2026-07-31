import Foundation
import KnittingCalculatorCore
import SwiftUI
import Testing
import UIKit
@testable import KnittingCalculator

struct CalculatorStoreScreenshotModeTests {
    @Test func screenshotArgumentsResolveOnlyWhenComplete() {
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: ["app"])
                == .notRequested
        )
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
                "-storeScreenshotScene", "gauge",
                "-storeScreenshotLanguage", "zh-Hant",
                "-storeScreenshotToken", "token-1",
            ]) == .ready(.init(
                scene: .gauge,
                language: .zhHant,
                readinessToken: "token-1"
            ))
        )
    }

    @Test func requestedScreenshotModeRejectsMissingOrUnknownValues() {
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
            ]) == .invalid
        )
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
                "-storeScreenshotScene", "unknown",
                "-storeScreenshotLanguage", "en",
                "-storeScreenshotToken", "token-2",
            ]) == .invalid
        )
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
                "-storeScreenshotScene", "home",
                "-storeScreenshotLanguage", "fr",
                "-storeScreenshotToken", "token-3",
            ]) == .invalid
        )
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
                "-storeScreenshotScene", "home",
                "-storeScreenshotLanguage", "en",
                "-storeScreenshotToken", "",
            ]) == .invalid
        )
    }

    @Test @MainActor
    func screenshotPreferencesUseDeterministicGaugeAndAdjustmentDrafts() {
        let mode = CalculatorStoreScreenshotMode(
            scene: .adjustment,
            language: .en,
            readinessToken: "preferences-\(UUID().uuidString)"
        )

        let preferences = mode.makePreferences()

        #expect(preferences.gauge == GaugeDraft(
            unit: .centimeters,
            sampleWidth: "10",
            sampleStitches: "20",
            targetWidth: "25",
            sampleHeight: "10",
            sampleRows: "30",
            targetHeight: "20"
        ))
        #expect(preferences.oneRow == OneRowAdjustmentDraft(
            currentStitches: "80",
            targetStitches: "92",
            reservesEdgeStitches: true
        ))
        #expect(preferences.rowInterval == RowIntervalAdjustmentDraft(
            totalRows: "20",
            totalStitches: "6",
            operation: .increase,
            style: .singleSide
        ))
    }

    @Test func screenshotScenesMapToApprovedPresentationBehavior() {
        #expect(CalculatorStoreScreenshotScene.home.presentation == .init(
            destination: .home,
            scrollTarget: .top,
            adjustmentMode: .oneRow,
            expandsAdjustmentRowDetails: false
        ))
        #expect(CalculatorStoreScreenshotScene.gauge.presentation == .init(
            destination: .gauge,
            scrollTarget: .top,
            adjustmentMode: .oneRow,
            expandsAdjustmentRowDetails: false
        ))
        #expect(CalculatorStoreScreenshotScene.adjustment.presentation == .init(
            destination: .adjustment,
            scrollTarget: .resultActions,
            adjustmentMode: .acrossRows,
            expandsAdjustmentRowDetails: true
        ))
        #expect(CalculatorStoreScreenshotScene.privacy.presentation == .init(
            destination: .settings,
            scrollTarget: .privacy,
            adjustmentMode: .oneRow,
            expandsAdjustmentRowDetails: false
        ))
        #expect(CalculatorStoreScreenshotScene.promotion.presentation == .init(
            destination: .home,
            scrollTarget: .promotion,
            adjustmentMode: .oneRow,
            expandsAdjustmentRowDetails: false
        ))
        #expect(CalculatorStoreScreenshotScene.privacyPromotion.presentation == .init(
            destination: .settings,
            scrollTarget: .privacy,
            adjustmentMode: .oneRow,
            expandsAdjustmentRowDetails: false
        ))
    }

    @Test func adjustmentScreenshotTargetsTheRealResultActionRegion() {
        let presentation = CalculatorStoreScreenshotScene.adjustment.presentation

        #expect(presentation.destination == .adjustment)
        #expect(presentation.adjustmentMode == .acrossRows)
        #expect(presentation.expandsAdjustmentRowDetails)
        #expect(presentation.scrollTarget.rawValue == "resultActions")
    }

    @Test @MainActor
    func screenshotRootKeepsReleaseDestinationsWhileScrollTargetsChooseTheVisibleRegion() {
        let home = CalculatorStoreScreenshotRootView(mode: .init(
            scene: .home,
            language: .en,
            readinessToken: "home"
        ))
        let promotion = CalculatorStoreScreenshotRootView(mode: .init(
            scene: .promotion,
            language: .en,
            readinessToken: "promotion"
        ))
        let privacy = CalculatorStoreScreenshotRootView(mode: .init(
            scene: .privacy,
            language: .en,
            readinessToken: "privacy"
        ))
        let privacyPromotion = CalculatorStoreScreenshotRootView(mode: .init(
            scene: .privacyPromotion,
            language: .en,
            readinessToken: "privacy-promotion"
        ))

        #expect(home.presentation.destination == promotion.presentation.destination)
        #expect(home.presentation.scrollTarget == .top)
        #expect(promotion.presentation.scrollTarget == .promotion)
        #expect(privacy.presentation.destination == privacyPromotion.presentation.destination)
        #expect(privacy.presentation.scrollTarget == .privacy)
        #expect(privacyPromotion.presentation.scrollTarget == .privacy)
    }

    @Test @MainActor
    func renderedHomeAndSettingsScenesKeepTheReleasePromotionAction() async {
        for scene in [
            CalculatorStoreScreenshotScene.home,
            .promotion,
            .privacy,
            .privacyPromotion,
        ] {
            let didRenderPromotion = await rendersPromotion(for: scene)

            #expect(
                didRenderPromotion,
                "Rendered \(scene.rawValue) must retain the Release KnitNote promotion"
            )
        }
    }

    @MainActor
    private func rendersPromotion(
        for scene: CalculatorStoreScreenshotScene
    ) async -> Bool {
        var didRenderPromotion = false
        let mode = CalculatorStoreScreenshotMode(
            scene: scene,
            language: .en,
            readinessToken: "render-\(scene.rawValue)-\(UUID().uuidString)"
        )
        let root = CalculatorStoreScreenshotRootView(mode: mode)
            .environmentObject(mode.makePreferences())
            .onKnitNotePromotionRendered {
                didRenderPromotion = true
            }
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 1_600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()

        window.isHidden = true
        return didRenderPromotion
    }
}
