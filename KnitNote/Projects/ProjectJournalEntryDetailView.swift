import SwiftUI

@MainActor
struct ProjectJournalEntryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    let entryID: UUID
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var deleteErrorKey: String?
#if os(iOS)
    @State private var shareSource: JournalShareSourceItem?
#endif

    var body: some View {
        NavigationStack {
            Group {
                if let project, let entry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ProjectJournalPhotoView(
                                url: store.journalPhotoURL(for: entry),
                                contentMode: .fit,
                                loadedAccessibilityLabelKey: "journal.accessibility.fullPhoto"
                            )
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 260, maxHeight: 640)
                            .clipShape(.rect(cornerRadius: 22, style: .continuous))

                            if let caption = entry.caption {
                                Text(caption)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text(entry.createdAt, format: .dateTime.year().month().day().locale(locale))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if project.isCompleted {
                                Label("journal.readOnly.completed", systemImage: "lock.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(WatercolorBackground())
                } else {
                    Color.clear
                }
            }
            .navigationTitle("journal.detail.title")
            .toolbar { journalToolbar }
            .confirmationDialog(
                "journal.delete.confirm.title",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("journal.delete", role: .destructive) { deleteEntry() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("journal.delete.confirm.message")
            }
            .alert("journal.error.delete.title", isPresented: deleteErrorIsPresented) {
                Button("common.retry") { deleteEntry() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(deleteErrorKey ?? "journal.error.deleteFailed"))
            }
            .sheet(isPresented: $showingEditor) {
                EditProjectJournalEntryView(projectID: projectID, entryID: entryID)
            }
#if os(iOS)
            .sheet(item: $shareSource) { item in
                JournalSharePreviewView(source: item.source, locale: locale)
                    .environment(\.locale, locale)
            }
#endif
        }
        .frame(minWidth: 340, minHeight: 480)
        .tint(WatercolorTheme.actionBerry)
        .task(id: entry?.id) {
            if project == nil || entry == nil {
                dismiss()
            }
        }
    }

    private var project: StoredProject? {
        store.project(id: projectID)
    }

    @ToolbarContentBuilder
    private var journalToolbar: some ToolbarContent {
        if let project, let entry {
#if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button("journal.share", systemImage: "square.and.arrow.up") {
                    openShare(project: project, entry: entry)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("journalShare.open")
            }
#endif
            if !project.isCompleted {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("journal.edit", systemImage: "pencil") { showingEditor = true }
                        .frame(minWidth: 44, minHeight: 44)
                    Button("journal.delete", systemImage: "trash", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

#if os(iOS)
    private func openShare(project: StoredProject, entry: ProjectJournalEntry) {
        guard let photoURL = store.journalPhotoURL(for: entry) else { return }
        shareSource = JournalShareSourceItem(source: JournalShareSource(
            projectName: project.name,
            entry: entry,
            photoURL: photoURL
        ))
    }
#endif

    private var entry: ProjectJournalEntry? {
        project?.journalEntries.first { $0.id == entryID }
    }

    private var deleteErrorIsPresented: Binding<Bool> {
        Binding(
            get: { deleteErrorKey != nil },
            set: { if !$0 { deleteErrorKey = nil } }
        )
    }

    private func deleteEntry() {
        do {
            try store.deleteJournalEntry(projectID: projectID, entryID: entryID)
            dismiss()
        } catch ProjectJournalMutationError.projectCompleted {
            deleteErrorKey = "journal.error.projectCompleted"
        } catch ProjectJournalMutationError.entryNotFound {
            dismiss()
        } catch {
            deleteErrorKey = "journal.error.deleteFailed"
        }
    }
}

#if os(iOS)
private struct JournalShareSourceItem: Identifiable {
    let id = UUID()
    let source: JournalShareSource
}
#endif
