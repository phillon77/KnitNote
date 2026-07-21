import SwiftUI

struct BackupSettingsSection: View {
    @EnvironmentObject private var store: JSONProjectStore
    @Environment(\.locale) private var locale

    @State private var activeOperation: BackupOperation?
    @State private var alertMessage: String?
    @State private var exportArtifactURL: URL?
    @State private var exportRequestToken: UUID?
    @State private var exportDocument: KnitNoteBackupDocument?
    @State private var exportFilename = "KnitNote"
    @State private var isExportingDocument = false
    @State private var isImportingDocument = false
    @State private var isShowingRestoreConfirmation = false
    @State private var pendingRestore: StagedKnitNoteBackup?
    @State private var restoreImportSessionToken: UUID?

    private var isBusy: Bool {
        store.isDataOperationInProgress || activeOperation != nil || exportArtifactURL != nil
    }

    private var isRestoreProgressVisible: Bool {
        activeOperation == .preparing || activeOperation == .restoring
    }

    private var restoreProgressAccessibilityKey: LocalizedStringKey {
        switch activeOperation {
        case .restoring:
            "backup.restoring"
        default:
            "backup.preparing"
        }
    }

    private var isAlertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                }
            }
        )
    }

    var body: some View {
        let importerSessionToken = restoreImportSessionToken
        backupRows
            .fileExporter(
                isPresented: $isExportingDocument,
                document: exportDocument,
                contentTypes: [.knitNoteBackup],
                defaultFilename: exportFilename,
                onCompletion: finishExport,
                onCancellation: finishExportCancellation
            )
            .fileImporter(
                isPresented: $isImportingDocument,
                allowedContentTypes: [.knitNoteBackup],
                allowsMultipleSelection: false
            ) { result in
                guard let importerSessionToken else { return }
                handleImport(result, requestToken: importerSessionToken)
            }
            .confirmationDialog(
                "backup.restore",
                isPresented: $isShowingRestoreConfirmation,
                titleVisibility: .visible
            ) {
                Button("backup.restore.confirm", role: .destructive, action: confirmRestore)
                Button("backup.cancel", role: .cancel, action: cancelPendingRestore)
            } message: {
                restoreConfirmationMessage
            }
            .alert("backup.section", isPresented: isAlertPresented) {
                Button("backup.alert.dismiss") {}
            } message: {
                if let message = alertMessage {
                    Text(LocalizedStringKey(message))
                }
            }
            .onChange(of: isShowingRestoreConfirmation) { _, isPresented in
                if !isPresented {
                    cancelPendingRestore()
                }
            }
            .onDisappear {
                invalidatePendingRequests()
                cancelPendingRestore()
            }
    }

    private var backupRows: some View {
        Section("backup.section") {
            Button(action: exportBackup) {
                operationLabel(
                    titleKey: "backup.export",
                    systemImage: "square.and.arrow.up",
                    showsProgress: activeOperation == .exporting,
                    progressAccessibilityKey: "backup.progress.accessibility"
                )
            }
            .accessibilityLabel("backup.export.accessibility")
            .disabled(isBusy)

            Button(action: beginImport) {
                operationLabel(
                    titleKey: "backup.restore",
                    systemImage: "square.and.arrow.down",
                    showsProgress: isRestoreProgressVisible,
                    progressAccessibilityKey: restoreProgressAccessibilityKey
                )
            }
            .accessibilityLabel("backup.restore.accessibility")
            .disabled(isBusy)
        }
    }

    @ViewBuilder private var restoreConfirmationMessage: some View {
        if let preview = pendingRestore?.preview {
            VStack(alignment: .leading) {
                Text("backup.replace.warning")
                Text("backup.preview.date")
                Text(preview.createdAt, format: .dateTime.year().month().day().hour().minute())
                Text(projectCountText(preview.projectCount))
                Text(yarnCountText(preview.yarnCount))
            }
        }
    }

    private func operationLabel(
        titleKey: LocalizedStringKey,
        systemImage: String,
        showsProgress: Bool,
        progressAccessibilityKey: LocalizedStringKey
    ) -> some View {
        HStack {
            Label(titleKey, systemImage: systemImage)
            Spacer()
            if showsProgress {
                ProgressView()
                    .accessibilityLabel(progressAccessibilityKey)
            }
        }
    }

    private func beginImport() {
        let requestToken = UUID()
        restoreImportSessionToken = requestToken
        isImportingDocument = true
    }

    private func exportBackup() {
        let requestToken = UUID()
        exportRequestToken = requestToken
        activeOperation = .exporting
        Task {
            do {
                let artifact = try await store.exportBackup(appVersion: appVersion)
                guard exportRequestToken == requestToken else {
                    store.cleanupBackupArtifact(at: artifact)
                    return
                }
                exportRequestToken = nil
                let filename = defaultExportFilename
                do {
                    exportDocument = try KnitNoteBackupDocument(
                        packageURL: artifact,
                        preferredFilename: "\(filename).knitnote-backup"
                    )
                } catch {
                    store.cleanupBackupArtifact(at: artifact)
                    throw error
                }
                exportArtifactURL = artifact
                exportFilename = filename
                activeOperation = nil
                isExportingDocument = true
            } catch {
                guard exportRequestToken == requestToken else { return }
                exportRequestToken = nil
                activeOperation = nil
                showError(BackupUserMessage.forExport(error))
            }
        }
    }

    private func finishExport(_ result: Result<URL, Error>) {
        defer {
            exportDocument = nil
            cleanupExportArtifact()
        }
        switch result {
        case .success:
            alertMessage = "backup.export.success"
        case let .failure(error):
            guard !error.isUserCancellation else { return }
            showError(.storageOrAccess)
        }
    }

    private func finishExportCancellation() {
        exportDocument = nil
        cleanupExportArtifact()
    }

    private func handleImport(_ result: Result<[URL], Error>, requestToken: UUID) {
        guard restoreImportSessionToken == requestToken else { return }
        switch result {
        case let .success(urls):
            guard let url = urls.first else {
                restoreImportSessionToken = nil
                return
            }
            inspectBackup(at: url, requestToken: requestToken)
        case let .failure(error):
            restoreImportSessionToken = nil
            guard !error.isUserCancellation else { return }
            showError(.storageOrAccess)
        }
    }

    private func inspectBackup(at url: URL, requestToken: UUID) {
        guard restoreImportSessionToken == requestToken else { return }
        activeOperation = .preparing
        Task {
            do {
                let staged = try await prepareSecurityScopedRestore(from: url)
                guard restoreImportSessionToken == requestToken else {
                    store.cancelBackupRestore(staged)
                    return
                }
                restoreImportSessionToken = nil
                cancelPendingRestore()
                pendingRestore = staged
                activeOperation = nil
                isShowingRestoreConfirmation = true
            } catch {
                guard restoreImportSessionToken == requestToken else { return }
                restoreImportSessionToken = nil
                activeOperation = nil
                showError(BackupUserMessage.forRestorePreparation(error))
            }
        }
    }

    private func prepareSecurityScopedRestore(from url: URL) async throws -> StagedKnitNoteBackup {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await store.prepareBackupRestore(from: url)
    }

    private func confirmRestore() {
        guard let staged = pendingRestore else { return }
        pendingRestore = nil
        activeOperation = .restoring
        Task {
            do {
                try await store.restoreBackup(staged)
                activeOperation = nil
                alertMessage = "backup.restore.success"
            } catch {
                store.cancelBackupRestore(staged)
                activeOperation = nil
                showError(BackupUserMessage.forRestore(error))
            }
        }
    }

    private func cancelPendingRestore() {
        guard let staged = pendingRestore else { return }
        pendingRestore = nil
        store.cancelBackupRestore(staged)
    }

    private func invalidatePendingRequests() {
        exportRequestToken = nil
        restoreImportSessionToken = nil
        switch activeOperation {
        case .exporting, .preparing:
            activeOperation = nil
        case .restoring, nil:
            break
        }
    }

    private func cleanupExportArtifact() {
        guard let artifact = exportArtifactURL else { return }
        exportArtifactURL = nil
        store.cleanupBackupArtifact(at: artifact)
    }

    private func showError(_ message: BackupUserMessage) {
        alertMessage = message.localizationKey
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var defaultExportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "KnitNote-\(formatter.string(from: .now))"
    }

    private func projectCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "backup.preview.projects", locale: locale),
            count
        )
    }

    private func yarnCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "backup.preview.yarns", locale: locale),
            count
        )
    }
}

private enum BackupOperation {
    case exporting
    case preparing
    case restoring
}

private enum BackupUserMessage {
    case exportFailed
    case invalidBackup
    case unsupportedVersion
    case storageOrAccess
    case originalPreserved
    case recoveryRequired
    case operationInProgress

    var localizationKey: String {
        switch self {
        case .exportFailed: "backup.error.exportFailed"
        case .invalidBackup: "backup.error.invalid"
        case .unsupportedVersion: "backup.error.unsupportedVersion"
        case .storageOrAccess: "backup.error.storageOrAccess"
        case .originalPreserved: "backup.restore.originalPreserved"
        case .recoveryRequired: "backup.restore.recoveryRequired"
        case .operationInProgress: "backup.error.operationInProgress"
        }
    }

    static func forExport(_ error: Error) -> Self {
        guard let backupError = error as? KnitNoteBackupError else { return .exportFailed }
        switch backupError {
        case .fileTooLarge, .packageTooLarge, .accessDenied:
            return .storageOrAccess
        case .operationInProgress:
            return .operationInProgress
        default:
            return .exportFailed
        }
    }

    static func forRestorePreparation(_ error: Error) -> Self {
        guard let backupError = error as? KnitNoteBackupError else { return .invalidBackup }
        switch backupError {
        case .unsupportedNewerVersion:
            return .unsupportedVersion
        case .fileTooLarge, .packageTooLarge, .accessDenied:
            return .storageOrAccess
        case .operationInProgress:
            return .operationInProgress
        default:
            return .invalidBackup
        }
    }

    static func forRestore(_ error: Error) -> Self {
        guard let backupError = error as? KnitNoteBackupError else { return .originalPreserved }
        switch backupError {
        case .rollbackFailed:
            return .recoveryRequired
        case .operationInProgress:
            return .operationInProgress
        case .fileTooLarge, .packageTooLarge, .accessDenied:
            return .storageOrAccess
        default:
            return .originalPreserved
        }
    }
}

private extension Error {
    var isUserCancellation: Bool {
        let error = self as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}
