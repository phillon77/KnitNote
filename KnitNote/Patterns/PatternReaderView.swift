import SwiftUI
#if os(iOS)
import UIKit
#endif

private struct PatternReaderPresentationModifier<Item: Identifiable, Reader: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let reader: (Item) -> Reader

    private var presentation: PatternReaderPresentation {
#if os(iOS)
        patternReaderPresentation(isPad: UIDevice.current.userInterfaceIdiom == .pad)
#else
        .sheet
#endif
    }

    func body(content: Content) -> some View {
#if os(iOS)
        if presentation == .fullScreen {
            content.fullScreenCover(item: $item, content: reader)
        } else {
            content.sheet(item: $item, content: reader)
        }
#else
        content.sheet(item: $item, content: reader)
#endif
    }
}

extension View {
    func patternReaderPresentation<Item: Identifiable, Reader: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Reader
    ) -> some View {
        modifier(PatternReaderPresentationModifier(item: item, reader: content))
    }
}

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
    @State private var originalPageNote = ""
    @State private var editingPageNoteIndex = 0
    @State private var markupMode = false
    @State private var markup = PatternMarkupDocument()
    @State private var markupTool = PatternMarkupTool.pen
    @State private var markupColor = MarkupColor.red
    @State private var markupWidth = 0.008
    @State private var confirmingMarkupClear = false
    @State private var expectedDataGeneration: UInt64?
    @State private var managingCounter: ProjectCounter?
    @StateObject private var pdfNavigator = PDFPageNavigator()
    private let counterRailSafeAreaWidth: CGFloat = 64

    init(projectID: UUID, pattern: PatternDocument) {
        self.projectID = projectID
        patternID = pattern.id
        _state = State(initialValue: pattern.readingState)
    }

    private var pattern: PatternDocument? { store.project(id: projectID)?.patterns.first { $0.id == patternID } }

    private var readerIsPad: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if let pattern, FileManager.default.fileExists(atPath: store.patternURL(projectID: projectID, pattern: pattern).path) {
                    VStack(spacing: 0) {
                        PatternMarkupToolbar(document: $markup, tool: $markupTool, color: $markupColor, width: $markupWidth, onClear: { confirmingMarkupClear = true }, onDone: finishMarkup)
                            .opacity(markupMode ? 1 : 0)
                            .allowsHitTesting(markupMode)
                            .accessibilityHidden(!markupMode)
                            .frame(height: PatternMarkupToolbar.stableHeight)

                        GeometryReader { proxy in
                            let layout = PatternReaderLayoutPolicy.resolve(
                                isPad: readerIsPad,
                                width: proxy.size.width,
                                height: proxy.size.height
                            )
                            VStack(spacing: 0) {
                                readerCanvas(pattern: pattern, layout: layout)
                                if pattern.kind == .pdf,
                                   pageCount > 0,
                                   layout.pageControlPlacement == .reservedBelow,
                                   !markupMode {
                                    PatternPageControls(
                                        pageIndex: state.pageIndex,
                                        pageCount: pageCount,
                                        onPreviousPage: { navigatePDF(by: -1) },
                                        onNextPage: { navigatePDF(by: 1) }
                                    )
                                    .background(.ultraThinMaterial)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView { Label("patterns.missing", systemImage: "exclamationmark.triangle") } actions: {
                        Button("patterns.removeRecord", role: .destructive) { try? store.deletePattern(projectID: projectID, id: patternID); dismiss() }
                    }
                }
            }
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
                        editingPageNoteIndex = state.pageIndex
                        originalPageNote = state.pageNote
                        showingPageNote = true
                    } label: {
                        Label("patterns.pageNote", systemImage: state.pageNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "doc.text" : "doc.text.fill")
                    }
                }
            }
            .alert("patterns.invalid", isPresented: $loadError) { Button("common.ok") { dismiss() } }
            .alert("error.saveFailed", isPresented: Binding(get:{saveError != nil},set:{if !$0{saveError=nil}})) { Button("common.ok"){} } message:{Text(saveError ?? "")}
            .sheet(isPresented: $showingPageNote, onDismiss: reloadSavedPageNote) {
                EditPatternPageNoteView(pageNumber: state.pageIndex + 1, text: $state.pageNote) {
                    savePageNoteDirectly()
                } onCancel: {
                    state.setPageNote(originalPageNote)
                }
            }
            .sheet(item: $managingCounter) { counter in
                EditCounterNameView(counter: counter) { name, value in
                    updateCounter(counter, name: name, value: value)
                }
            }
            .confirmationDialog("patterns.markup.clear.confirm", isPresented: $confirmingMarkupClear) {
                Button("patterns.markup.clear", role: .destructive) { markup.clear() }
                Button("common.cancel", role: .cancel) {}
            }
        }
        .tint(WatercolorTheme.actionBerry)
        .interactiveDismissDisabled()
        .onAppear {
            if expectedDataGeneration == nil { expectedDataGeneration = store.dataGeneration }
            loadMarkup(page: state.pageIndex)
        }
        .onDisappear { saveMarkup(page: state.pageIndex); _ = save() }
        .onChange(of: state.pageIndex) { oldPage, newPage in saveMarkup(page: oldPage); loadMarkup(page: newPage) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveMarkup(page: state.pageIndex); _ = save() } }
    }

    @ViewBuilder
    private func readerCanvas(
        pattern: PatternDocument,
        layout: PatternReaderLayoutPolicy
    ) -> some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if pattern.kind == .pdf {
                    PDFReaderView(
                        url: store.patternURL(projectID: projectID, pattern: pattern),
                        navigator: pdfNavigator,
                        state: $state,
                        pageCount: $pageCount,
                        loadError: $loadError
                    )
                    .allowsHitTesting(!markupMode)
                } else {
                    ImageReaderView(
                        url: store.patternURL(projectID: projectID, pattern: pattern),
                        state: $state,
                        loadError: $loadError
                    )
                    .allowsHitTesting(!markupMode)
                }
                if state.highlightEnabled {
                    HighlightOverlay(
                        mode: state.highlightMode,
                        horizontalPosition: $state.highlightPosition,
                        verticalPosition: $state.verticalHighlightPosition
                    )
                    .allowsHitTesting(!markupMode)
                }
                if markupMode {
                    PatternMarkupOverlay(
                        document: $markup,
                        tool: markupTool,
                        color: markupColor,
                        width: markupWidth
                    )
                }
            }
            .padding(.trailing, counterRailSafeAreaWidth)
            .accessibilityLabel(Text(pattern.displayName))

            if let project = store.project(id: projectID), !markupMode {
                PatternReaderControls(
                    counters: project.counters,
                    isEnabled: !project.isCompleted,
                    pageIndex: state.pageIndex,
                    pageCount: pattern.kind == .pdf ? pageCount : 0,
                    showsOverlayPageControls: layout.pageControlPlacement == .overlay,
                    onPreviousPage: { navigatePDF(by: -1) },
                    onNextPage: { navigatePDF(by: 1) },
                    onIncrement: incrementCounter,
                    onManage: { counterID in
                        managingCounter = project.counters.first { $0.id == counterID }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @discardableResult private func save() -> Bool {
        state.saveCurrentPage()
        do {
            try store.updatePatternState(
                projectID: projectID,
                id: patternID,
                state: state,
                expectedDataGeneration: expectedDataGeneration
            )
            return true
        }
        catch { saveError=error.localizedDescription; return false }
    }

    private func incrementCounter(_ counterID: UUID) {
        do {
            try store.selectCounter(projectID: projectID, counterID: counterID)
            try store.incrementCounter(projectID: projectID, counterID: counterID)
        }
        catch { saveError = error.localizedDescription }
    }

    private func updateCounter(_ counter: ProjectCounter, name: String, value: Int) {
        do { try store.updateCounter(projectID: projectID, counterID: counter.id, name: name, value: value) }
        catch { saveError = error.localizedDescription }
    }

    private func navigatePDF(by delta: Int) {
        guard pageCount > 0 else { return }
        let target = min(pageCount - 1, max(0, state.pageIndex + delta))
        guard target != state.pageIndex else { return }
        pdfNavigator.go(to: target)
    }

    private func savePageNoteDirectly() {
        let text = state.pageNote
        do {
            try store.savePatternPageNote(
                projectID: projectID,
                patternID: patternID,
                pageIndex: editingPageNoteIndex,
                text: text,
                expectedDataGeneration: expectedDataGeneration
            )
            if editingPageNoteIndex == state.pageIndex { state.setPageNote(text) }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func reloadSavedPageNote() {
        guard editingPageNoteIndex == state.pageIndex,
              let saved = store.project(id: projectID)?.patterns.first(where: { $0.id == patternID })?.pageStates[editingPageNoteIndex]?.note else { return }
        state.setPageNote(saved)
    }

    private func loadMarkup(page: Int) {
        do {
            markup = try store.loadPatternMarkup(
                projectID: projectID,
                patternID: patternID,
                pageIndex: page
            )
        }
        catch { markup = PatternMarkupDocument(); saveError = error.localizedDescription }
    }

    private func saveMarkup(page: Int) {
        guard let expectedDataGeneration else { return }
        do {
            try store.savePatternMarkup(
                markup,
                projectID: projectID,
                patternID: patternID,
                pageIndex: page,
                expectedDataGeneration: expectedDataGeneration
            )
        }
        catch { saveError = error.localizedDescription }
    }

    private func finishMarkup() { saveMarkup(page: state.pageIndex); markupMode = false }
}
