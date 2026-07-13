import SwiftUI

struct ProjectDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var showingEdit = false
    @State private var editingRow: Int?
    @State private var showingAllNotes = false
    @State private var showingPatterns = false
    @State private var showGlint = false

    var body: some View {
        if let project = store.project(id: projectID) {
            ZStack {
                WatercolorBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        Text(project.name)
                            .font(.title2.bold())
                            .foregroundStyle(WatercolorTheme.ink)
                        WatercolorCard {
                            ZStack(alignment: .topTrailing) {
                                VStack(spacing: 4) {
                                    Text("project.currentRow")
                                        .foregroundStyle(.secondary)
                                    Text(project.currentRow, format: .number)
                                        .font(.system(size: 88, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(WatercolorTheme.ink)
                                }
                                .frame(maxWidth: .infinity)
                                Image(systemName: "sparkle")
                                    .foregroundStyle(WatercolorTheme.flower)
                                    .scaleEffect(showGlint ? 1.2 : 0.01)
                                    .opacity(showGlint ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                        }
                        Button(action: completeRow) {
                            Label("project.completeRow", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(YarnPrimaryButtonStyle())

                        HStack(spacing: 10) {
                            supportingButton("project.undo", icon: "arrow.uturn.backward") {
                                try? store.undoRow(id: projectID)
                            }
                            .disabled(project.currentRow == 0)
                            supportingButton("notes.edit", icon: "note.text") { editingRow = project.currentRow }
                            supportingButton("patterns.open", icon: "doc.text.image") { showingPatterns = true }
                        }

                        if !project.sortedNotes.isEmpty {
                            WatercolorCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("notes.recent").font(.headline)
                                    ForEach(project.sortedNotes.prefix(3)) { note in
                                        Button { editingRow = note.row } label: {
                                            HStack {
                                                Text(note.row, format: .number).font(.headline.monospacedDigit())
                                                Text(note.text).lineLimit(1)
                                                Spacer()
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    if project.rowNotes.count > 3 {
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
            .toolbar { Button("project.edit", systemImage: "pencil") { showingEdit = true } }
            .sheet(isPresented: $showingEdit) { EditProjectView(projectID: projectID) }
            .sheet(item: $editingRow) { EditRowNoteView(projectID: projectID, row: $0) }
            .sheet(isPresented: $showingAllNotes) { AllNotesView(projectID: projectID) }
            .sheet(isPresented: $showingPatterns) { ProjectPatternsView(projectID: projectID) }
        }
    }

    private func completeRow() {
        try? store.completeRow(id: projectID)
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.18)) { showGlint = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.easeIn(duration: 0.18)) { showGlint = false }
        }
    }

    private func supportingButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(WatercolorTheme.actionBerry)
        .accessibilityLabel(Text(title))
    }
}

extension Int: @retroactive Identifiable { public var id: Int { self } }
