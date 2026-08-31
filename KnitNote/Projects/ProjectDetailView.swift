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
    @EnvironmentObject private var reminderPresentationStore: KnittingReminderPresentationStore
    let projectID: UUID
    @State private var reminderSurfaceID = UUID()
    @State private var reminderLease: KnittingReminderPresentationLease?
    @State private var showingEdit = false
    @State private var editingNote: CounterRowSelection?
    @State private var managingCounter: ProjectCounter?
    @State private var showingAllNotes = false
    @State private var showingPatterns = false
    @State private var showingJournalEditor = false
    @State private var selectedJournalEntry: JournalEntryRoute?
    @State private var showingKnittingReminders = false
    @State private var showingCalculators = false
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

                        WatercolorCard {
                            Button {
                                showingKnittingReminders = true
                            } label: {
                                Label("knittingReminder.list.title", systemImage: "bell.badge")
                                Spacer()
                                Text(project.activeKnittingReminderCount, format: .number)
                            }
                            .buttonStyle(.plain)
                        }

                        if isQueueCardActuallyVisible, let reminderLease {
                            KnittingReminderQueueCard(
                                projectID: projectID,
                                project: project,
                                lease: reminderLease,
                                isActuallyVisible: isQueueCardActuallyVisible
                            )
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
                            Button {
                                showingCalculators = true
                            } label: {
                                Label("calculator.tools.title", systemImage: "ruler")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
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
            .navigationDestination(isPresented: $showingKnittingReminders) {
                KnittingReminderListView(projectID: projectID)
            }
            .navigationDestination(isPresented: $showingCalculators) {
                KnittingCalculatorsView()
            }
            .sheet(isPresented: $showingEdit) {
                EditProjectView(projectID: projectID) {
                    showingEdit = false
                    dismiss()
                }
            }
            .sheet(item: $managingCounter) { counter in
                CounterManagerView(
                    counter: counter,
                    projectID: projectID,
                    mainCounterID: project.mainCounterID,
                    reminderID: project.knittingReminders.first { $0.counterID == counter.id }?.id
                ) { save in
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
            .onAppear {
                synchronizeReminderLease()
            }
            .onChange(of: isQueueCardActuallyVisible) { _, _ in
                synchronizeReminderLease()
            }
            .onDisappear {
                releaseReminderLease()
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
                reminder: .unchanged
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

    private var isQueueCardActuallyVisible: Bool {
        guard let project = store.project(id: projectID) else { return false }
        return !project.isCompleted
            && !showingEdit
            && managingCounter == nil
            && editingNote == nil
            && !showingAllNotes
            && !showingPatterns
            && !showingJournalEditor
            && selectedJournalEntry == nil
            && !showingKnittingReminders
            && !showingCalculators
            && counterSaveError == nil
    }

    private func synchronizeReminderLease() {
        reminderLease = reminderPresentationStore.synchronizeSurface(
            projectID: projectID,
            surfaceID: reminderSurfaceID,
            isVisible: isQueueCardActuallyVisible,
            lease: reminderLease
        )
    }

    private func releaseReminderLease() {
        guard let reminderLease else { return }
        reminderPresentationStore.releaseSurface(
            projectID: projectID,
            lease: reminderLease
        )
        self.reminderLease = nil
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
