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
        let appInitializer = try entitlementProjectionFunction(
            signature: "    init()",
            in: app
        )
        let localFactory = try entitlementProjectionClosure(
            after: "makeLocal:",
            in: appInitializer
        )
        let snapshotCallback = try entitlementProjectionClosure(
            after: "onSnapshotChange:",
            in: localFactory
        )

        #expect(writer.contains("data.write"))
        #expect(writer.contains("options: .atomic"))
        #expect(coordinator.contains("onSnapshotChange"))
        #expect(coordinator.contains("publishSnapshot("))
        #expect(localFactory.contains(
            "let entitlementProjection = try? EntitlementProjectionWriter.live()"
        ))
        #expect(localFactory.contains("EntitlementCoordinator.configured("))
        #expect(snapshotCallback.contains(
            "try? entitlementProjection?.write(snapshot: snapshot, generatedAt: generatedAt)"
        ))
        #expect(
            appInitializer.components(separatedBy: "EntitlementProjectionWriter.live()").count == 2
        )
        #expect(
            localFactory.components(separatedBy: "EntitlementProjectionWriter.live()").count == 2
        )
        #expect(
            appInitializer.components(separatedBy: "entitlementProjection?.write(").count == 2
        )
        #expect(
            snapshotCallback.components(separatedBy: "entitlementProjection?.write(").count == 2
        )
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

private func entitlementProjectionFunction(signature: String, in source: String) throws -> String {
    let signatures = source.components(separatedBy: signature)
    guard signatures.count == 2,
          let start = source.range(of: signature)?.lowerBound,
          let openingBrace = source[start...].firstIndex(of: "{") else {
        throw EntitlementProjectionContractError.missingUniqueOwner
    }
    return try entitlementProjectionBracedBlock(from: start, openingBrace: openingBrace, in: source)
}

private func entitlementProjectionClosure(after marker: String, in source: String) throws -> String {
    let markers = source.components(separatedBy: marker)
    guard markers.count == 2,
          let markerRange = source.range(of: marker),
          let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{") else {
        throw EntitlementProjectionContractError.missingUniqueOwner
    }
    return try entitlementProjectionBracedBlock(
        from: markerRange.lowerBound,
        openingBrace: openingBrace,
        in: source
    )
}

private func entitlementProjectionBracedBlock(
    from start: String.Index,
    openingBrace: String.Index,
    in source: String
) throws -> String {
    var depth = 0
    var cursor = openingBrace
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[start...cursor])
            }
        default:
            break
        }
        cursor = source.index(after: cursor)
    }
    throw EntitlementProjectionContractError.missingUniqueOwner
}

private enum EntitlementProjectionContractError: Error {
    case missingUniqueOwner
}
