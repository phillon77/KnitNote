import SwiftUI

struct CounterRowSelection: Identifiable {
    let counterID: UUID
    let row: Int

    var id: String { "\(counterID.uuidString)-\(row)" }
}

private struct JournalEntryRoute: Identifiable {
    let id: UUID
}

struct ProjectDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var showingEdit = false
    @State private var editingNote: CounterRowSelection?
    @State private var managingCounter: ProjectCounter?
    @State private var showingAllNotes = false
    @State private var showingPatterns = false
    @State private var showingJournalEditor = false
    @State private var selectedJournalEntry: JournalEntryRoute?
    @State private var counterSaveError: String?

    var body: some View {
        if let project = store.project(id: projectID) {
            ZStack {
                WatercolorBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        ProjectCoverView(project: project)
                            .frame(width: 96, height: 96)
                            .clipShape(.rect(cornerRadius: 22))

                        if project.isCompleted {
                            Label("project.status.completed", systemImage: "checkmark.seal.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(WatercolorTheme.actionBerry)
                        }

                        projectActionCard("patterns.open", icon: "doc.text.image", isPopulated: hasActivePatterns) {
                            showingPatterns = true
                        }

                        projectActionCard("notes.edit", icon: "note.text", isPopulated: project.counters.contains { !$0.rowNotes.isEmpty }) {
                            editingNote = CounterRowSelection(
                                counterID: project.selectedCounterID,
                                row: project.selectedCounter.value
                            )
                        }

                        let sortedNotes = project.selectedCounter.rowNotes.sorted { $0.row > $1.row }
                        if !sortedNotes.isEmpty {
                            WatercolorCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("notes.recent")
                                        .font(.headline)
                                    ForEach(sortedNotes.prefix(3)) { note in
                                        Button {
                                            editingNote = CounterRowSelection(
                                                counterID: project.selectedCounterID,
                                                row: note.row
                                            )
                                        } label: {
                                            HStack {
                                                Text(note.row, format: .number)
                                                    .font(.headline.monospacedDigit())
                                                Text(note.text)
                                                    .lineLimit(1)
                                                Spacer()
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    if sortedNotes.count > 3 {
                                        Button("notes.all") { showingAllNotes = true }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        WatercolorCard {
                            CounterSelectorGrid(
                                counters: project.counters,
                                selectedCounterID: project.selectedCounterID,
                                isEnabled: !project.isCompleted,
                                onIncrement: { counterID in
                                    _ = try? store.selectCounter(projectID: projectID, counterID: counterID)
                                    _ = try? store.incrementCounter(projectID: projectID, counterID: counterID)
                                },
                                onManage: { counterID in
                                    _ = try? store.selectCounter(projectID: projectID, counterID: counterID)
                                    managingCounter = project.counters.first { $0.id == counterID }
                                }
                            )
                        }

                        if let reminder = project.selectedCounter.reminder {
                            if let pending = reminder.pending {
                                let counterID = project.selectedCounterID
                                CounterReminderCard(
                                    pending: pending,
                                    message: reminder.message,
                                    onComplete: {
                                        completeProjectCounterReminder(counterID: counterID, pending: pending)
                                    },
                                    onStop: {
                                        stopProjectCounterReminder(counterID: counterID, pending: pending)
                                    }
                                )
                            }
                        }

                        WatercolorCard {
                            ProjectYarnSection(
                                projectID: projectID,
                                isEditable: !project.isCompleted
                            )
                        }

                        WatercolorCard {
                            ProjectJournalSection(
                                project: project,
                                thumbnailURL: store.journalThumbnailURL(for:),
                                onAdd: { showingJournalEditor = true },
                                onOpen: { entry in
                                    selectedJournalEntry = JournalEntryRoute(id: entry.id)
                                }
                            )
                        }

                        if hasToolDetails(project) {
                            WatercolorCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("project.tool.section")
                                        .font(.headline)
                                    if let toolType = project.toolType {
                                        LabeledContent("project.tool.type") {
                                            Text(toolTypeLocalizationKey(toolType))
                                        }
                                    }
                                    if let toolSize = project.toolSize,
                                       !toolSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        LabeledContent("project.tool.size") {
                                            Text(toolSize)
                                        }
                                    }
                                    if let toolNotes = project.toolNotes,
                                       !toolNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        LabeledContent("project.tool.notes") {
                                            Text(toolNotes)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        WatercolorCard {
                            NavigationLink {
                                KnittingCalculatorsView()
                            } label: {
                                Label("calculator.tools.title", systemImage: "ruler")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                    }
                    .padding()
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(project.name)
            .toolbar {
                Button("project.edit", systemImage: "pencil") { showingEdit = true }
            }
            .sheet(isPresented: $showingEdit) {
                EditProjectView(projectID: projectID) {
                    showingEdit = false
                    dismiss()
                }
            }
            .sheet(item: $managingCounter) { counter in
                CounterManagerView(counter: counter) { save in
                    saveCounter(counter, save: save)
                }
            }
            .sheet(item: $editingNote) { selection in
                EditRowNoteView(
                    projectID: projectID,
                    counterID: selection.counterID,
                    row: selection.row
                )
            }
            .sheet(isPresented: $showingAllNotes) {
                AllNotesView(projectID: projectID, counterID: project.selectedCounterID)
            }
            .sheet(isPresented: $showingPatterns) {
                ProjectPatternsView(projectID: projectID)
                    .environment(\.locale, locale)
#if os(macOS)
                    .frame(
                        minWidth: CGFloat(KnitNoteMacWindowSizingPolicy.minimumWidth),
                        minHeight: CGFloat(KnitNoteMacWindowSizingPolicy.minimumHeight)
                    )
#endif
            }
            .sheet(isPresented: $showingJournalEditor) {
                EditProjectJournalEntryView(projectID: projectID)
            }
            .sheet(item: $selectedJournalEntry) { route in
                ProjectJournalEntryDetailView(projectID: projectID, entryID: route.id)
            }
            .alert("error.saveFailed", isPresented: Binding(
                get: { counterSaveError != nil },
                set: { if !$0 { counterSaveError = nil } }
            )) {
                Button("common.ok") {}
            } message: {
                Text(counterSaveError ?? "")
            }
        }
    }

    private func saveCounter(_ counter: ProjectCounter, save: CounterManagerSave) -> Bool {
        do {
            guard let _ = try store.manageCounter(
                projectID: projectID,
                counterID: counter.id,
                name: save.name,
                value: save.value,
                reminder: save.reminderEdit
            ) else {
                counterSaveError = LocaleAwareText.string("counter.error.notSaved", locale: locale)
                return false
            }
            return true
        } catch {
            counterSaveError = error.localizedDescription
            return false
        }
    }

    private func completeProjectCounterReminder(
        counterID: UUID,
        pending: CounterReminderPending
    ) {
        do {
            guard let currentProject = store.project(id: projectID),
                  currentProject.selectedCounterID == counterID,
                  let currentCounter = currentProject.counters.first(where: { $0.id == counterID }),
                  currentCounter.id == counterID,
                  let currentReminder = currentCounter.reminder,
                  currentReminder.id == pending.reminderID,
                  let currentPending = currentReminder.pending,
                  currentPending.reminderID == pending.reminderID,
                  currentPending.occurrenceCount == pending.occurrenceCount else {
                reminderActionFailed()
                return
            }
            let dataGenerationBefore = store.dataGeneration
            try store.completeCounterReminder(
                projectID: projectID,
                counterID: counterID,
                reminderID: pending.reminderID,
                observedCount: pending.occurrenceCount
            )
            guard store.dataGeneration > dataGenerationBefore,
                  let updatedProject = store.project(id: projectID),
                  updatedProject.selectedCounterID == counterID,
                  let updatedCounter = updatedProject.counters.first(where: { $0.id == counterID }),
                  updatedCounter.id == counterID,
                  let updatedReminder = updatedCounter.reminder,
                  updatedReminder.id == pending.reminderID,
                  updatedReminder.pending == nil else {
                reminderActionFailed()
                return
            }
        } catch {
            counterSaveError = error.localizedDescription
        }
    }

    private func stopProjectCounterReminder(
        counterID: UUID,
        pending: CounterReminderPending
    ) {
        do {
            guard let currentProject = store.project(id: projectID),
                  currentProject.selectedCounterID == counterID,
                  let currentCounter = currentProject.counters.first(where: { $0.id == counterID }),
                  currentCounter.id == counterID,
                  let currentReminder = currentCounter.reminder,
                  currentReminder.id == pending.reminderID,
                  currentReminder.isActive == true,
                  let currentPending = currentReminder.pending,
                  currentPending.reminderID == pending.reminderID,
                  currentPending.occurrenceCount == pending.occurrenceCount else {
                reminderActionFailed()
                return
            }
            let dataGenerationBefore = store.dataGeneration
            try store.stopCounterReminder(
                projectID: projectID,
                counterID: counterID,
                reminderID: pending.reminderID
            )
            guard store.dataGeneration > dataGenerationBefore,
                  let updatedProject = store.project(id: projectID),
                  updatedProject.selectedCounterID == counterID,
                  let updatedCounter = updatedProject.counters.first(where: { $0.id == counterID }),
                  updatedCounter.id == counterID,
                  let updatedReminder = updatedCounter.reminder,
                  updatedReminder.id == pending.reminderID,
                  updatedReminder.pending == nil,
                  updatedReminder.isActive != true else {
                reminderActionFailed()
                return
            }
        } catch {
            counterSaveError = error.localizedDescription
        }
    }

    private func reminderActionFailed() {
        counterSaveError = LocaleAwareText.string("counter.error.notSaved", locale: locale)
    }

    private var hasActivePatterns: Bool {
        store.patternUsages.contains {
            $0.projectID == projectID && $0.isActive
        }
    }

    private func hasToolDetails(_ project: StoredProject) -> Bool {
        let hasSize = !(project.toolSize?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let hasNotes = !(project.toolNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        return project.toolType != nil || hasSize || hasNotes
    }

    private func toolTypeLocalizationKey(_ toolType: ProjectToolType) -> LocalizedStringKey {
        switch toolType {
        case .crochetHook:
            "project.tool.type.crochetHook"
        case .knittingNeedles:
            "project.tool.type.knittingNeedles"
        case .other:
            "project.tool.type.other"
        }
    }

    private func projectActionCard(
        _ title: LocalizedStringKey,
        icon: String,
        isPopulated: Bool,
        action: @escaping () -> Void
    ) -> some View {
        WatercolorCard {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .foregroundStyle(isPopulated ? WatercolorTheme.actionBerry : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}
