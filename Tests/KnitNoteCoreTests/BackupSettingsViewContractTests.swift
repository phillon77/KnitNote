import Foundation
import Testing

@Suite struct BackupSettingsViewContractTests {
    @Test func settingsContainsBackupSectionAndBothSystemPickers() throws {
        let settings = try source("KnitNote/Settings/SettingsView.swift")
        let backup = try source("KnitNote/Settings/BackupSettingsSection.swift")

        #expect(settings.contains("BackupSettingsSection()"))
        #expect(backup.contains("fileExporter"))
        #expect(backup.contains("fileImporter"))
        #expect(backup.contains("confirmationDialog"))
        #expect(backup.contains("isDataOperationInProgress"))
        #expect(backup.contains("startAccessingSecurityScopedResource"))
        #expect(!backup.contains("import KnitNoteCore"))
        #expect(backup.contains("@State private var alertMessage: String?"))
        #expect(backup.contains("Text(LocalizedStringKey(message))"))
        #expect(backup.contains("backup.preparing"))
        #expect(backup.contains("backup.restoring"))
    }

    @Test func restoreStagesBeforeConfirmationAndCleansUpUnusedArtifacts() throws {
        let backup = try source("KnitNote/Settings/BackupSettingsSection.swift")

        #expect(backup.contains("prepareBackupRestore"))
        #expect(backup.contains("StagedKnitNoteBackup"))
        #expect(backup.contains("restoreBackup"))
        #expect(backup.contains("cancelBackupRestore"))
        #expect(backup.contains("cleanupBackupArtifact"))
        #expect(backup.contains("onDisappear"))
    }

    @Test func exportUsesANamedPackageDocumentAndOwnsSourceUntilCompletion() throws {
        let document = try source("KnitNote/Settings/KnitNoteBackupDocument.swift")
        let backup = try source("KnitNote/Settings/BackupSettingsSection.swift")
        let disappearance = try textBetween(
            backup,
            start: ".onDisappear {",
            end: "\n            }"
        )
        let completion = try textBetween(
            backup,
            start: "private func finishExport(",
            end: "private func finishExportCancellation("
        )
        let cancellation = try textBetween(
            backup,
            start: "private func finishExportCancellation(",
            end: "private func handleImport("
        )

        #expect(document.contains("struct KnitNoteBackupDocument: FileDocument"))
        #expect(document.contains("KnitNoteBackupExportPackage"))
        #expect(document.contains("preferredFilename: preferredFilename"))
        #expect(!document.contains("FileRepresentation"))
        #expect(!document.contains("SentTransferredFile"))
        #expect(!document.contains("@unchecked Sendable"))
        #expect(backup.contains("document: exportDocument"))
        #expect(backup.contains("onCancellation: finishExportCancellation"))
        #expect(!disappearance.contains("cleanupExportArtifact"))
        #expect(completion.contains("cleanupExportArtifact()"))
        #expect(cancellation.contains("cleanupExportArtifact()"))
    }

    @Test func exportBuildsTheDocumentWithANonemptyPackageFilename() throws {
        let backup = try source("KnitNote/Settings/BackupSettingsSection.swift")

        #expect(backup.contains("document: exportDocument"))
        #expect(backup.contains("@State private var exportDocument: KnitNoteBackupDocument?"))
        #expect(backup.contains("preferredFilename: \"\\(filename).knitnote-backup\""))
        #expect(backup.contains("exportArtifactURL = artifact"))
    }

    @Test func backupExtensionIsExportedAsASelectablePackageDocument() throws {
        let document = try source("KnitNote/Settings/KnitNoteBackupDocument.swift")
        let project = try source("project.yml")

        #expect(document.contains(
            "UTType(exportedAs: \"com.phillon.KnitNote.backup\", conformingTo: .package)"
        ))
        #expect(project.contains("UTExportedTypeDeclarations:"))
        #expect(project.contains("bundleIdPrefix: com.phillon"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote\n"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.watch"))
        #expect(project.contains("UTTypeIdentifier: com.phillon.KnitNote.backup"))
        #expect(project.contains("- com.apple.package"))
        #expect(project.contains("- knitnote-backup"))
        #expect(!project.contains("com.example"))
    }

    @Test func exportAndImportUseExactTokensInvalidatedOnEveryDisappearance() throws {
        let backup = try source("KnitNote/Settings/BackupSettingsSection.swift")
        let disappearance = try textBetween(
            backup,
            start: ".onDisappear {",
            end: "\n            }"
        )
        let invalidation = try textBetween(
            backup,
            start: "private func invalidatePendingRequests()",
            end: "private func cleanupExportArtifact()"
        )

        #expect(backup.contains("@State private var exportRequestToken: UUID?"))
        #expect(backup.contains("@State private var restoreImportSessionToken: UUID?"))
        #expect(backup.contains("guard exportRequestToken == requestToken else"))
        #expect(backup.contains("guard restoreImportSessionToken == requestToken else"))
        #expect(backup.contains("store.cleanupBackupArtifact(at: artifact)"))
        #expect(backup.contains("store.cancelBackupRestore(staged)"))
        #expect(disappearance.contains("invalidatePendingRequests()"))
        #expect(invalidation.contains("exportRequestToken = nil"))
        #expect(invalidation.contains("restoreImportSessionToken = nil"))
        #expect(!backup.contains("viewIsVisible"))
    }

    @Test func importerSessionTokenIsCapturedBeforePresentationAndRequiredThroughPreparation() throws {
        let backup = try source("KnitNote/Settings/BackupSettingsSection.swift")
        let importer = try textBetween(
            backup,
            start: ".fileImporter(",
            end: ".confirmationDialog("
        )
        let beginImport = try textBetween(
            backup,
            start: "private func beginImport()",
            end: "private func exportBackup()"
        )
        let importHandling = try textBetween(
            backup,
            start: "private func handleImport(",
            end: "private func inspectBackup("
        )
        let preparation = try textBetween(
            backup,
            start: "private func inspectBackup(",
            end: "private func prepareSecurityScopedRestore("
        )
        let invalidation = try textBetween(
            backup,
            start: "private func invalidatePendingRequests()",
            end: "private func cleanupExportArtifact()"
        )
        let assignment = try #require(beginImport.range(of: "restoreImportSessionToken = requestToken"))
        let presentation = try #require(beginImport.range(of: "isImportingDocument = true"))

        #expect(backup.contains("@State private var restoreImportSessionToken: UUID?"))
        #expect(backup.contains("let importerSessionToken = restoreImportSessionToken"))
        #expect(importer.contains("guard let importerSessionToken else { return }"))
        #expect(importer.contains("handleImport(result, requestToken: importerSessionToken)"))
        #expect(backup.contains("Button(action: beginImport)"))
        #expect(beginImport.contains("let requestToken = UUID()"))
        #expect(assignment.lowerBound < presentation.lowerBound)
        #expect(importHandling.contains("requestToken: UUID"))
        #expect(importHandling.contains("guard restoreImportSessionToken == requestToken else { return }"))
        #expect(importHandling.contains("inspectBackup(at: url, requestToken: requestToken)"))
        #expect(preparation.contains("requestToken: UUID"))
        #expect(preparation.contains("guard restoreImportSessionToken == requestToken else"))
        #expect(!preparation.contains("let requestToken = UUID()"))
        #expect(invalidation.contains("restoreImportSessionToken = nil"))
    }

    @Test func everyBackupKeyHasEnglishAndTraditionalChinese() throws {
        let root = repositoryRoot
        let catalogData = try Data(
            contentsOf: root.appendingPathComponent("KnitNote/Localization/Localizable.xcstrings")
        )
        let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in BackupLocalizationContract.requiredKeys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations["en"] != nil)
            #expect(localizations["zh-Hant"] != nil)
        }
    }
}

private enum BackupLocalizationContract {
    static let requiredKeys = [
        "backup.section",
        "backup.export",
        "backup.restore",
        "backup.preview.date",
        "backup.preview.projects",
        "backup.preview.yarns",
        "backup.replace.warning",
        "backup.restore.confirm",
        "backup.cancel",
        "backup.preparing",
        "backup.restoring",
        "backup.export.success",
        "backup.restore.success",
        "backup.error.exportFailed",
        "backup.error.invalid",
        "backup.error.unsupportedVersion",
        "backup.error.storageOrAccess",
        "backup.restore.originalPreserved",
        "backup.restore.recoveryRequired",
        "backup.error.operationInProgress",
        "backup.export.accessibility",
        "backup.restore.accessibility",
        "backup.progress.accessibility"
    ]
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func source(_ relativePath: String) throws -> String {
    try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func textBetween(_ source: String, start: String, end: String) throws -> String {
    let startRange = try #require(source.range(of: start))
    let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
    return String(source[startRange.lowerBound..<endRange.upperBound])
}
