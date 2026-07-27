import Foundation
import Testing

@Suite struct ShareExtensionEntitlementContractTests {
    @Test func mainAppAtomicallyPublishesEveryAuthoritativeSnapshot() throws {
        let writer = try readRepositoryFile(
            "KnitNote/Entitlements/EntitlementProjectionWriter.swift"
        )
        let coordinator = try readRepositoryFile(
            "KnitNote/Entitlements/EntitlementCoordinator.swift"
        )
        let app = try readRepositoryFile("KnitNote/App/KnitNoteApp.swift")

        #expect(writer.contains("data.write"))
        #expect(writer.contains("options: .atomic"))
        #expect(coordinator.contains("onSnapshotChange"))
        #expect(coordinator.contains("publishSnapshot("))
        #expect(app.contains("EntitlementProjectionWriter.live()"))
        #expect(app.contains("entitlementProjectionWriter?.write("))
    }

    @Test func shareGateRunsBeforeProviderSelectionOrByteLoading() throws {
        let reader = try readRepositoryFile(
            "KnitNoteShare/EntitlementProjectionReader.swift"
        )
        let controller = try readRepositoryFile(
            "KnitNoteShare/ShareImportController.swift"
        )

        #expect(reader.contains("EntitlementProjection.canAcceptImport("))
        #expect(reader.contains("JSONDecoder"))
        #expect(reader.contains("fileExists"))

        let gate = try #require(controller.range(
            of: "entitlementReader.canAcceptImport"
        ))
        let selection = try #require(controller.range(
            of: "PatternShareImportProviderSelection.select"
        ))
        let byteLoad = try #require(controller.range(
            of: "session.start()"
        ))
        #expect(gate.lowerBound < selection.lowerBound)
        #expect(gate.lowerBound < byteLoad.lowerBound)
        #expect(controller.contains("state = .entitlementBlocked"))
    }

    @Test func blockedStateOffersOpenKnitNoteWithoutEnqueueing() throws {
        let controller = try readRepositoryFile(
            "KnitNoteShare/ShareImportController.swift"
        )
        let view = try readRepositoryFile("KnitNoteShare/ShareImportView.swift")
        let project = try readRepositoryFile("project.yml")

        #expect(controller.contains("extensionContext.open("))
        #expect(controller.contains("knitnote://open"))
        #expect(view.contains("share.entitlement.blocked"))
        #expect(view.contains("share.openKnitNote"))
        #expect(view.contains("controller.openKnitNote()"))
        #expect(project.contains("CFBundleURLSchemes"))
        #expect(project.contains("knitnote"))
    }

    @Test func failedOpenAttemptClosesInsteadOfLeavingShareSheetStuck() throws {
        let controller = try readRepositoryFile(
            "KnitNoteShare/ShareImportController.swift"
        )
        let openFunction = try #require(controller.range(
            of: "func openKnitNote()"
        ))
        let nextFunction = try #require(controller.range(
            of: "func cancelIfNeeded()"
        ))
        let functionSource = controller[openFunction.lowerBound..<nextFunction.lowerBound]

        #expect(functionSource.contains("extensionContext.open("))
        #expect(functionSource.contains("self?.completeRequest()"))
        #expect(!functionSource.contains("guard opened else"))
    }

    @Test func inboxProcessingWaitsForVerifiedEntitlementPreparation() throws {
        let root = try readRepositoryFile("KnitNote/App/RootView.swift")

        let preparation = try #require(root.range(
            of: "await entitlementCoordinator.ensurePrepared()"
        ))
        let processing = try #require(root.range(
            of: "patternInboxProcessor.processPending()"
        ))
        #expect(preparation.lowerBound < processing.lowerBound)
        #expect(root.contains("scenePhase == .active"))
        #expect(root.contains(".task(id: scenePhase)"))
    }

    @Test func blockedGuidanceIsLocalizedInEnglishAndTraditionalChinese() throws {
        let data = try Data(contentsOf: patternLibraryRepositoryURL(
            "KnitNoteShare/Localizable.xcstrings"
        ))
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])

        for key in ["share.entitlement.blocked", "share.openKnitNote"] {
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
