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
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var showingEdit = false
    @State private var editingNote: CounterRowSelection?
    @State private var managingCounter: ProjectCounter?
    @State private var showingAllNotes = false
    @State private var showingPatterns = false
    @State private var showingJournalEditor = false
    @State private var selectedJournalEntry: JournalEntryRoute?

    var body: some View {
        if let project = store.project(id: projectID) {
            ZStack {
                WatercolorBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        ProjectPhotoView(url: store.photoURL(for: project))
                            .frame(width: 96, height: 96)
                            .clipShape(.rect(cornerRadius: 22))

                        if project.isCompleted {
                            Label("project.status.completed", systemImage: "checkmark.seal.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(WatercolorTheme.actionBerry)
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
                            CounterSelectorGrid(
                                counters: project.counters,
                                selectedCounterID: project.selectedCounterID,
                                isEnabled: !project.isCompleted,
                                onIncrement: { counterID in
                                    try? store.selectCounter(projectID: projectID, counterID: counterID)
                                    try? store.incrementCounter(projectID: projectID, counterID: counterID)
                                },
                                onManage: { counterID in
                                    try? store.selectCounter(projectID: projectID, counterID: counterID)
                                    managingCounter = project.counters.first { $0.id == counterID }
                                }
                            )
                        }

                        WatercolorCard {
                            NavigationLink {
                                KnittingCalculatorsView()
                            } label: {
                                Label("calculator.tools.title", systemImage: "ruler")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        projectActionCard("notes.edit", icon: "note.text") {
                            editingNote = CounterRowSelection(
                                counterID: project.selectedCounterID,
                                row: project.selectedCounter.value
                            )
                        }

                        projectActionCard("patterns.open", icon: "doc.text.image") {
                            showingPatterns = true
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
                EditProjectView(projectID: projectID)
            }
            .sheet(item: $managingCounter) { counter in
                EditCounterNameView(counter: counter) { name, value in
                    try? store.updateCounter(projectID: projectID, counterID: counter.id, name: name, value: value)
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
            }
            .sheet(isPresented: $showingJournalEditor) {
                EditProjectJournalEntryView(projectID: projectID)
            }
            .sheet(item: $selectedJournalEntry) { route in
                ProjectJournalEntryDetailView(projectID: projectID, entryID: route.id)
            }
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
        action: @escaping () -> Void
    ) -> some View {
        WatercolorCard {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}
