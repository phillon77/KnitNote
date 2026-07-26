import Foundation
import Testing

@Suite struct ShareExtensionFlowContractTests {
    @Test func extensionLoadsOneProviderAndOnlyEnqueuesTheOwnedFile() throws {
        let controllerURL = patternLibraryRepositoryURL(
            "KnitNoteShare/ShareImportController.swift"
        )
        let exists = FileManager.default.fileExists(atPath: controllerURL.path)

        #expect(exists)
        guard exists else { return }

        let source = try String(contentsOf: controllerURL, encoding: .utf8)
        #expect(source.contains("PatternShareImportProviderSelection.select("))
        #expect(source.contains("loadFileRepresentation("))
        #expect(source.contains("PatternShareInboxEnqueuer("))
        #expect(source.contains("workerQueue.sync"))
        #expect(source.contains("PatternShareImportCompletionGate"))
        #expect(source.contains(".timeout()"))
        #expect(source.contains("providerProgress?.cancel()"))
        #expect(!source.contains("JSONProjectStore"))
        #expect(!source.contains("openURL"))
    }

    @Test func extensionAlwaysFinishesThroughItsExtensionContext() throws {
        let controllerURL = patternLibraryRepositoryURL(
            "KnitNoteShare/ShareImportController.swift"
        )
        let viewControllerURL = patternLibraryRepositoryURL(
            "KnitNoteShare/ShareViewController.swift"
        )
        let viewURL = patternLibraryRepositoryURL(
            "KnitNoteShare/ShareImportView.swift"
        )
        let paths = [controllerURL, viewControllerURL, viewURL]

        for path in paths {
            #expect(FileManager.default.fileExists(atPath: path.path))
        }
        guard paths.allSatisfy({
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return }

        let controller = try String(contentsOf: controllerURL, encoding: .utf8)
        let view = try String(contentsOf: viewURL, encoding: .utf8)
        #expect(controller.contains("completeRequest("))
        #expect(controller.contains("cancelRequest("))
        #expect(view.contains(".accessibilityLabel("))
        #expect(view.contains("share.success"))
        #expect(view.contains("share.error."))
    }
}
