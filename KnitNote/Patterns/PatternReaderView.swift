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
    @State private var markupMode = false
    @State private var markup = PatternMarkupDocument()
    @State private var markupTool = PatternMarkupTool.pen
    @State private var markupColor = MarkupColor.red
    @State private var markupWidth = 0.008
    @State private var confirmingMarkupClear = false
    @StateObject private var pdfNavigator = PDFPageNavigator()
    private let files = PatternFileService.live()
    private let markupFiles = PatternMarkupFileService.live()

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
                    VStack(spacing: 0) {
                        PatternMarkupToolbar(document: $markup, tool: $markupTool, color: $markupColor, width: $markupWidth, onClear: { confirmingMarkupClear = true }, onDone: finishMarkup)
                            .opacity(markupMode ? 1 : 0)
                            .allowsHitTesting(markupMode)
                            .accessibilityHidden(!markupMode)
                            .frame(height: PatternMarkupToolbar.stableHeight)

                        ZStack(alignment: .top) {
                            if pattern.kind == .pdf {
                                PDFReaderView(url: files.url(projectID: projectID, pattern: pattern), navigator: pdfNavigator, state: $state, pageCount: $pageCount, loadError: $loadError)
                                    .allowsHitTesting(!markupMode)
                            } else {
                                ImageReaderView(url: files.url(projectID: projectID, pattern: pattern), state: $state, loadError: $loadError)
                                    .allowsHitTesting(!markupMode)
                            }
                            if state.highlightEnabled { HighlightOverlay(mode: state.highlightMode, horizontalPosition: $state.highlightPosition, verticalPosition: $state.verticalHighlightPosition).allowsHitTesting(!markupMode) }
                            if markupMode { PatternMarkupOverlay(document: $markup, tool: markupTool, color: markupColor, width: markupWidth) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                        if let project = store.project(id: projectID) {
                            PatternReaderControls(
                                currentRow: project.currentRow,
                                pageIndex: state.pageIndex,
                                pageCount: pattern.kind == .pdf ? pageCount : 0,
                                onPreviousPage: { navigatePDF(by: -1) },
                                onNextPage: { navigatePDF(by: 1) },
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
                    Button("patterns.markup", systemImage: "pencil.and.outline") { markupMode.toggle() }
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
            .confirmationDialog("patterns.markup.clear.confirm", isPresented: $confirmingMarkupClear) {
                Button("patterns.markup.clear", role: .destructive) { markup.clear() }
                Button("common.cancel", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled()
        .onAppear { loadMarkup(page: state.pageIndex) }
        .onDisappear { saveMarkup(page: state.pageIndex); _ = save() }
        .onChange(of: state.pageIndex) { oldPage, newPage in saveMarkup(page: oldPage); loadMarkup(page: newPage) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveMarkup(page: state.pageIndex); _ = save() } }
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

    private func navigatePDF(by delta: Int) {
        guard pageCount > 0 else { return }
        let target = min(pageCount - 1, max(0, state.pageIndex + delta))
        guard target != state.pageIndex else { return }
        pdfNavigator.go(to: target)
    }

    private func loadMarkup(page: Int) {
        do { markup = try markupFiles.load(projectID: projectID, patternID: patternID, pageIndex: page) }
        catch { markup = PatternMarkupDocument(); saveError = error.localizedDescription }
    }

    private func saveMarkup(page: Int) {
        do { try markupFiles.save(markup, projectID: projectID, patternID: patternID, pageIndex: page) }
        catch { saveError = error.localizedDescription }
    }

    private func finishMarkup() { saveMarkup(page: state.pageIndex); markupMode = false }
}
