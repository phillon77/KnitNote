import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

private struct ProjectPatternDuplicateSelection {
    let itemID: UUID
    let candidatePatternIDs: [UUID]
}

struct PatternImportResultView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID

    @State private var showingFileImporter = false
    @State private var showingCamera = false
    @State private var operationCoordinator = ProjectPatternImportOperationCoordinator()
    @State private var importTask: Task<Void, Never>?
    @State private var successMessage: LocalizedStringKey?
    @State private var pendingSelection: ProjectPatternDuplicateSelection?
    @State private var errorMessage: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            Group {
                if isImporting {
                    ProgressView("patterns.import.processing")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(Text("patterns.import.processing"))
                } else if let successMessage {
                    ContentUnavailableView {
                        Label("patterns.import.success.title", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text(successMessage)
                    }
                } else if let pendingSelection {
                    duplicateChooser(pendingSelection)
                } else {
                    sourceChooser
                }
            }
            .background(WatercolorBackground())
            .navigationTitle("patterns.importNew")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(successMessage == nil ? "common.cancel" : "common.done") {
                        cancelCurrentOperation()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .png, .jpeg, .heic]
            ) { result in
                importFileResult(result)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCaptureView { data in
                    importCameraData(data)
                }
                .ignoresSafeArea()
            }
            #endif
            .alert(
                "patterns.error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("common.ok") {}
            } message: {
                Text(errorMessage ?? "patterns.import.error.unexpected")
                    .accessibilityLabel(
                        Text(errorMessage ?? "patterns.import.error.unexpected")
                    )
            }
        }
        .tint(WatercolorTheme.actionBerry)
        .onDisappear {
            cancelCurrentOperation()
        }
    }

    private var isImporting: Bool {
        operationCoordinator.isRunning
    }

    private var sourceChooser: some View {
        VStack(spacing: 16) {
            Button {
                showingFileImporter = true
            } label: {
                Label("patterns.import.files", systemImage: "folder")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)

            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showingCamera = true
                } label: {
                    Label("patterns.import.camera", systemImage: "camera")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            #endif
        }
        .padding()
        .frame(maxWidth: 440, maxHeight: .infinity)
    }

    private func duplicateChooser(
        _ selection: ProjectPatternDuplicateSelection
    ) -> some View {
        List(selection.candidatePatternIDs, id: \.self) { patternID in
            if let pattern = store.patterns.first(where: { $0.id == patternID }) {
                Button {
                    resolveDuplicate(itemID: selection.itemID, patternID: patternID)
                } label: {
                    HStack(spacing: 14) {
                        PatternThumbnailView(patternID: patternID)
                            .frame(width: 60, height: 76)
                        Text(pattern.displayName)
                            .foregroundStyle(WatercolorTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(pattern.displayName))
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("patterns.import.chooseDuplicate")
    }

    private func importFileResult(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            startOperation {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try await store.importPatternFromProject(
                    url,
                    projectID: projectID
                )
            }
        case let .failure(error):
            presentError(error, context: .filePicker)
        }
    }

    private func importCameraData(_ data: Data) {
        startOperation {
            let name = String(
                localized: "patterns.import.cameraName",
                locale: locale
            )
            let url = try await ProjectPatternCameraTemporaryFile.write(
                data: data,
                displayName: name
            )
            do {
                let outcome = try await store.importPatternFromProject(
                    url,
                    projectID: projectID
                )
                await ProjectPatternCameraTemporaryFile.remove(url)
                return outcome
            } catch {
                await ProjectPatternCameraTemporaryFile.remove(url)
                throw error
            }
        }
    }

    private func startOperation(
        _ operation: @escaping @MainActor () async throws -> PatternImportOutcome
    ) {
        cancelCurrentOperation()
        let operationID = operationCoordinator.begin()
        errorMessage = nil
        importTask = Task { @MainActor in
            do {
                let outcome = try await operation()
                try Task.checkCancellation()
                guard operationCoordinator.finishIfCurrent(operationID) else {
                    return
                }
                importTask = nil
                accept(outcome)
            } catch is CancellationError {
                guard operationCoordinator.finishIfCurrent(operationID) else {
                    return
                }
                importTask = nil
            } catch {
                guard operationCoordinator.finishIfCurrent(operationID) else {
                    return
                }
                importTask = nil
                presentError(error)
            }
        }
    }

    private func resolveDuplicate(itemID: UUID, patternID: UUID) {
        startOperation {
            try await store.processPatternInboxItem(
                id: itemID,
                selectingPatternID: patternID
            )
        }
    }

    private func cancelCurrentOperation() {
        operationCoordinator.cancel()
        importTask?.cancel()
        importTask = nil
    }

    private func presentError(
        _ error: any Error,
        context: ProjectPatternImportFailureContext = .operation
    ) {
        let message = ProjectPatternImportErrorMapper.message(
            for: error,
            context: context
        )
        errorMessage = LocalizedStringKey(message.rawValue)
    }

    private func accept(_ outcome: PatternImportOutcome) {
        switch outcome {
        case .created:
            pendingSelection = nil
            successMessage = "patterns.import.success.created"
        case .existing:
            pendingSelection = nil
            successMessage = "patterns.import.success.existing"
        case let .needsSelection(itemID, candidatePatternIDs):
            successMessage = nil
            pendingSelection = ProjectPatternDuplicateSelection(
                itemID: itemID,
                candidatePatternIDs: candidatePatternIDs
            )
        }
    }
}

private enum ProjectPatternCameraTemporaryFile {
    static func write(data: Data, displayName: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "KnitNote-PatternCamera-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory
                .appendingPathComponent(displayName)
                .appendingPathExtension("jpg")
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    static func remove(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }.value
    }
}
