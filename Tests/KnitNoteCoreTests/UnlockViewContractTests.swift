import Foundation
import Testing

@Suite struct UnlockViewContractTests {
    @Test func projectsHomeAloneHostsTheQuietActiveTrialPill() throws {
        let projects = try readRepositoryFile("KnitNote/Projects/ProjectsView.swift")
        let pill = try readRepositoryFile(
            "KnitNote/Entitlements/TrialStatusPill.swift"
        )
        let root = try readRepositoryFile("KnitNote/App/RootView.swift")

        #expect(projects.contains("TrialStatusPill("))
        #expect(projects.contains("onShowUnlock"))
        #expect(pill.contains("UnlockPresentation.activeTrialExpiry("))
        #expect(pill.contains("now: context.date"))
        #expect(pill.contains("by: 60"))
        #expect(pill.contains("@Environment(\\.locale)"))
        #expect(pill.contains("locale: locale"))
        #expect(!projects.contains("snapshot.state(at: .now)"))
        #expect(!root.contains("TrialStatusPill("))
    }

    @Test func rootPresentsOneUnlockSheetForPillAndBlockedMutation() throws {
        let root = try readRepositoryFile("KnitNote/App/RootView.swift")

        #expect(root.contains("@EnvironmentObject private var entitlementCoordinator"))
        #expect(root.contains("UnlockSheet()"))
        #expect(root.contains("onShowUnlock:"))
        #expect(root.contains(".onChange(of: entitlementCoordinator.unlockRequest)"))
        #expect(root.contains(".onChange(of: entitlementCoordinator.snapshot)"))
        #expect(root.contains("UnlockPresentation.shouldDismissUnlock("))
        #expect(root.contains("entitlementCoordinator.dismissUnlock()"))
    }

    @Test func unlockSheetUsesCoordinatorFacadeAndPreventsDuplicateActions() throws {
        let sheet = try readRepositoryFile("KnitNote/Entitlements/UnlockSheet.swift")
        let coordinator = try readRepositoryFile(
            "KnitNote/Entitlements/EntitlementCoordinator.swift"
        )
        let storeKit = try readRepositoryFile(
            "KnitNote/Entitlements/StoreKitPurchaseService.swift"
        )

        #expect(sheet.contains("coordinator.localizedLifetimePrice"))
        #expect(sheet.contains("coordinator.purchaseLifetime()"))
        #expect(sheet.contains("coordinator.restorePurchases()"))
        #expect(sheet.contains("coordinator.refreshEntitlement()"))
        #expect(sheet.contains("@Environment(\\.locale)"))
        #expect(sheet.contains("locale: locale"))
        #expect(sheet.contains(
            ".accessibilityLabel(purchaseAccessibilityLabel)"
        ))
        #expect(sheet.contains(".disabled(isBusy)"))
        #expect(sheet.contains(".accessibilityLabel"))
        #expect(sheet.contains("AppStore.presentOfferCodeRedeemSheet"))
        #expect(sheet.contains("#if os(iOS)"))
        #expect(sheet.contains("#elseif os(macOS)"))
        #expect(sheet.contains("import AppKit"))
        #expect(sheet.contains("from: controller"))
        #expect(coordinator.contains("private let purchaseService"))
        #expect(storeKit.contains("lifetimeProduct?.displayPrice"))
        #expect(!sheet.contains("PurchaseService"))
    }

    @Test func unlockCopyIsTranslatedInEnglishAndTraditionalChinese() throws {
        let data = try Data(contentsOf: patternLibraryRepositoryURL(
            "KnitNote/Localization/Localizable.xcstrings"
        ))
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let keys = [
            "unlock.trial.active.one",
            "unlock.trial.active.many.format",
            "unlock.trial.accessibility.one",
            "unlock.trial.accessibility.many.format",
            "unlock.title",
            "unlock.expired.dataRetained",
            "unlock.lifetime.message",
            "unlock.purchase.format",
            "unlock.purchase.unavailable",
            "unlock.pending",
            "unlock.cancelled",
            "unlock.restore",
            "unlock.restore.notFound",
            "unlock.redeem",
            "unlock.redeem.unavailable",
            "unlock.retry",
            "unlock.readOnly",
            "unlock.watch.guidance",
            "unlock.accessibility.purchase",
            "unlock.accessibility.purchase.format",
            "unlock.accessibility.restore",
            "unlock.accessibility.redeem",
            "unlock.accessibility.dismiss",
        ]

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            for language in ["en", "zh-Hant"] {
                let localization = try #require(
                    localizations[language] as? [String: Any]
                )
                let unit = try #require(
                    localization["stringUnit"] as? [String: Any]
                )
                #expect((unit["value"] as? String)?.isEmpty == false)
            }
        }
    }
}
