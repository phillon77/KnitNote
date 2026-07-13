import SwiftUI

struct PatternReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    let patternID: UUID
    @State private var state: PatternReadingState
    @State private var loadError = false
    @State private var pageCount = 0
    @State private var saveError: String?
    @State private var showingPageNote = false
    private let files = PatternFileService.live()

    init(projectID: UUID, pattern: PatternDocument) {
        self.projectID = projectID
        patternID = pattern.id
        _state = State(initialValue: pattern.readingState)
    }

    private var pattern: PatternDocument? { store.project(id: projectID)?.patterns.first { $0.id == patternID } }

    var body: some View {
        NavigationStack {
            Group {
                if let pattern, FileManager.default.fileExists(atPath: files.url(projectID: projectID, pattern: pattern).path) {
                    ZStack(alignment: .top) {
                        if pattern.kind == .pdf {
                            PDFReaderView(url: files.url(projectID: projectID, pattern: pattern), state: $state, pageCount: $pageCount, loadError: $loadError)
                        } else {
                            ImageReaderView(url: files.url(projectID: projectID, pattern: pattern), state: $state, loadError: $loadError)
                        }
                        if state.highlightEnabled { HighlightOverlay(mode: state.highlightMode, horizontalPosition: $state.highlightPosition, verticalPosition: $state.verticalHighlightPosition) }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let project = store.project(id: projectID) {
                            PatternReaderControls(
                                currentRow: project.currentRow,
                                pageIndex: state.pageIndex,
                                pageCount: pattern.kind == .pdf ? pageCount : 0,
                                onPreviousPage: { state.movePDFPage(by: -1, pageCount: pageCount) },
                                onNextPage: { state.movePDFPage(by: 1, pageCount: pageCount) },
                                onUndoRow: undoRow,
                                onCompleteRow: completeRow
                            )
                        }
                    }
                } else {
                    ContentUnavailableView { Label("patterns.missing", systemImage: "exclamationmark.triangle") } actions: {
                        Button("patterns.removeRecord", role: .destructive) { try? store.deletePattern(projectID: projectID, id: patternID); dismiss() }
                    }
                }
            }
            .navigationTitle(pattern?.displayName ?? String(localized: "patterns.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.ok") { if save() { dismiss() } } }
                ToolbarItem(placement: .primaryAction) { Toggle("patterns.highlight", isOn: $state.highlightEnabled) }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("patterns.highlightMode", selection: $state.highlightMode) {
                            Text("patterns.highlight.horizontal").tag(HighlightMode.horizontal)
                            Text("patterns.highlight.vertical").tag(HighlightMode.vertical)
                            Text("patterns.highlight.cross").tag(HighlightMode.cross)
                        }
                    } label: { Label("patterns.highlightMode", systemImage: "scope") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingPageNote = true
                    } label: {
                        Label("patterns.pageNote", systemImage: state.pageNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "doc.text" : "doc.text.fill")
                    }
                }
            }
            .alert("patterns.invalid", isPresented: $loadError) { Button("common.ok") { dismiss() } }
            .alert("error.saveFailed", isPresented: Binding(get:{saveError != nil},set:{if !$0{saveError=nil}})) { Button("common.ok"){} } message:{Text(saveError ?? "")}
            .sheet(isPresented: $showingPageNote) {
                EditPatternPageNoteView(pageNumber: state.pageIndex + 1, initialText: state.pageNote) { text in
                    state.pageNote = text
                    state.saveCurrentPage()
                    _ = save()
                }
            }
        }
        .interactiveDismissDisabled()
        .onDisappear { _ = save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { _ = save() } }
    }

    @discardableResult private func save() -> Bool {
        state.saveCurrentPage()
        do { try store.updatePatternState(projectID: projectID, id: patternID, state: state); return true }
        catch { saveError=error.localizedDescription; return false }
    }

    private func completeRow() {
        do { try store.completeRow(id: projectID) }
        catch { saveError = error.localizedDescription }
    }

    private func undoRow() {
        do { try store.undoRow(id: projectID) }
        catch { saveError = error.localizedDescription }
    }
}
