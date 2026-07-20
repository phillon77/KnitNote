import SwiftUI

@MainActor
struct EditProjectJournalEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    let entryID: UUID?
    @State private var selectedPhotoData: Data?
    @State private var caption = ""
    @State private var isPhotoLoading = false
    @State private var isSaving = false
    @State private var publicationGate = ProjectJournalAsyncPublicationGate()
    @State private var saveTask: Task<Void, Never>?
    @State private var errorKey: String?
    @State private var availabilityErrorKey: String?
    @State private var didLoadEntry = false

    init(projectID: UUID, entryID: UUID? = nil) {
        self.projectID = projectID
        self.entryID = entryID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let entry {
                        ProjectJournalPhotoView(
                            url: store.journalPhotoURL(for: entry),
                            contentMode: .fit
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 220, maxHeight: 420)
                        .clipShape(.rect(cornerRadius: 20, style: .continuous))
                    } else if entryID == nil {
                        JournalPhotoPicker(
                            selectedData: $selectedPhotoData,
                            isLoading: $isPhotoLoading
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("journal.caption.label")
                            .font(.headline)
                        TextField("journal.caption.placeholder", text: $caption, axis: .vertical)
                            .lineLimit(3...8)
                            .textFieldStyle(.roundedBorder)
                    }

                    if isSaving {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("journal.saving")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding()
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(WatercolorBackground())
            .navigationTitle(entryID == nil ? "journal.add.title" : "journal.edit.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { save() }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!canSave)
                }
            }
            .alert("journal.error.save.title", isPresented: errorIsPresented) {
                Button("common.retry") { save() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(errorKey ?? "journal.error.saveFailed"))
            }
            .alert("journal.error.save.title", isPresented: availabilityAlertIsPresented) {
                Button("common.ok") { dismiss() }
            } message: {
                Text(LocalizedStringKey(availabilityErrorKey ?? "journal.error.notFound"))
            }
        }
        .frame(minWidth: 340, minHeight: 480)
        .tint(WatercolorTheme.actionBerry)
        .interactiveDismissDisabled(isSaving)
        .onAppear(perform: loadEntryDraft)
        .task(id: availabilityStateID) {
            updateAvailability()
        }
        .onDisappear {
            publicationGate.cancel()
            saveTask?.cancel()
            saveTask = nil
        }
    }

    private var project: StoredProject? {
        store.project(id: projectID)
    }

    private var entry: ProjectJournalEntry? {
        project?.journalEntries.first { $0.id == entryID }
    }

    private var canSave: Bool {
        guard !isSaving, !isPhotoLoading, let project, !project.isCompleted else { return false }
        if entryID == nil && selectedPhotoData == nil {
            return false
        }
        return entry != nil
            || (entryID == nil && selectedPhotoData != nil)
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorKey != nil },
            set: { if !$0 { errorKey = nil } }
        )
    }

    private var availabilityAlertIsPresented: Binding<Bool> {
        Binding(
            get: { availabilityErrorKey != nil },
            set: { if !$0 { dismiss() } }
        )
    }

    private var availabilityStateID: String {
        guard let project else { return "project-missing" }
        if project.isCompleted {
            return "project-completed-\(project.updatedAt.timeIntervalSinceReferenceDate)"
        }
        if entryID != nil, entry == nil {
            return "entry-missing-\(project.updatedAt.timeIntervalSinceReferenceDate)"
        }
        return "available-\(project.updatedAt.timeIntervalSinceReferenceDate)"
    }

    private func updateAvailability() {
        guard !isSaving else { return }
        if project == nil {
            availabilityErrorKey = "journal.error.notFound"
        } else if project?.isCompleted == true {
            availabilityErrorKey = "journal.error.projectCompleted"
        } else if entryID != nil, entry == nil {
            availabilityErrorKey = "journal.error.notFound"
        }
    }

    private func loadEntryDraft() {
        guard !didLoadEntry, let entry else { return }
        caption = entry.caption ?? ""
        didLoadEntry = true
    }

    private func save() {
        guard !isSaving else { return }
        guard canSave else { return }
        isSaving = true
        errorKey = nil
        let captionDraft = caption
        let photoData = selectedPhotoData
        let revision = publicationGate.begin()

        saveTask = Task {
            do {
                try Task.checkCancellation()
                if let entryID {
                    try store.updateJournalCaption(
                        projectID: projectID,
                        entryID: entryID,
                        caption: captionDraft
                    )
                } else if let photoData {
                    try await store.addJournalEntry(
                        projectID: projectID,
                        photoData: photoData,
                        caption: captionDraft
                    )
                }
                try Task.checkCancellation()
                guard publicationGate.finish(revision) else { return }
                finishSaving()
                dismiss()
            } catch is CancellationError {
                guard publicationGate.finish(revision) else { return }
                finishSaving()
            } catch {
                guard publicationGate.finish(revision) else { return }
                finishSaving()
                errorKey = journalErrorKey(error)
            }
        }
    }

    private func finishSaving() {
        isSaving = false
        saveTask = nil
    }

    private func journalErrorKey(_ error: Error) -> String {
        switch error {
        case ProjectJournalMutationError.projectCompleted:
            "journal.error.projectCompleted"
        case ProjectJournalMutationError.entryNotFound:
            "journal.error.notFound"
        case ProjectJournalPhotoFileError.invalidImage:
            "journal.error.invalidImage"
        default:
            "journal.error.saveFailed"
        }
    }
}
