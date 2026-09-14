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
    @State private var shareSource: JournalShareSourceItem?

    var body: some View {
        NavigationStack {
            Group {
                if let project, let entry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            #if os(macOS)
                            MacJournalDetailActionBar(
                                isCompleted: project.isCompleted,
                                onShare: { openShare(project: project, entry: entry) },
                                onEdit: { showingEditor = true },
                                onDelete: { showingDeleteConfirmation = true }
                            )
                            #endif

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
            #if os(iOS)
            .toolbar { journalToolbar }
            #endif
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
            .sheet(item: $shareSource) { item in
                JournalSharePreviewView(source: item.source, locale: locale)
                    .environment(\.locale, locale)
            }
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
            ToolbarItem(placement: .primaryAction) {
                Button("journal.share", systemImage: "square.and.arrow.up") {
                    openShare(project: project, entry: entry)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("journalShare.open")
            }
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

    private func openShare(project: StoredProject, entry: ProjectJournalEntry) {
        guard let photoURL = store.journalPhotoURL(for: entry) else { return }
        shareSource = JournalShareSourceItem(source: JournalShareSource(
            projectName: project.name,
            entry: entry,
            photoURL: photoURL
        ))
    }

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

#if os(macOS)
struct MacJournalDetailActionBar: View {
    let isCompleted: Bool
    let onShare: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actions }
            VStack(spacing: 12) { actions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        Button("journal.share", systemImage: "square.and.arrow.up", action: onShare)
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("journalShare.open")

        if !isCompleted {
            Button("journal.edit", systemImage: "pencil", action: onEdit)
                .frame(minWidth: 44, minHeight: 44)
            Button("journal.delete", systemImage: "trash", role: .destructive, action: onDelete)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}
#endif

private struct JournalShareSourceItem: Identifiable {
    let id = UUID()
    let source: JournalShareSource
}
