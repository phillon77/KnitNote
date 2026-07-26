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

private enum PatternReaderSource {
    case library(PatternReaderContext)
    case legacy(projectID: UUID, patternID: UUID)
}

private struct PatternReaderContent {
    let displayName: String
    let kind: PatternKind
    let url: URL
}

struct PatternReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: JSONProjectStore
    private let source: PatternReaderSource
    @State private var state: PatternReadingState
    @State private var didLoadContextState = false
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
    private let onStoreScreenshotReady: @MainActor () -> Void

    /// Archive-level reader entry point. A library context loads state only
    /// from its usage; a standalone context begins with fresh, ephemeral state.
    init(
        context: PatternReaderContext,
        onStoreScreenshotReady: @escaping @MainActor () -> Void = {}
    ) {
        source = .library(context)
        _state = State(initialValue: .init())
        self.onStoreScreenshotReady = onStoreScreenshotReady
    }

    /// Compatibility entry point for un-migrated project-owned pattern screens.
    /// New library callers must use `init(context:)` so their writes are keyed
    /// by `PatternProjectUsage.id`.
    init(
        projectID: UUID,
        pattern: PatternDocument,
        storePresentation: PatternReaderStorePresentation = .standard,
        onStoreScreenshotReady: @escaping @MainActor () -> Void = {}
    ) {
        source = .legacy(projectID: projectID, patternID: pattern.id)
        var initialState = pattern.readingState
        switch storePresentation {
        case .standard:
            break
        case .highlight:
            initialState.highlightEnabled = true
            initialState.highlightMode = .horizontal
        case .crossHighlight:
            initialState.highlightEnabled = true
            initialState.highlightMode = .cross
        case .markup, .notes:
            break
        }
        _state = State(initialValue: initialState)
        _markupMode = State(initialValue: storePresentation == .markup)
        _showingPageNote = State(initialValue: storePresentation == .notes)
        self.onStoreScreenshotReady = onStoreScreenshotReady
    }

    private var context: PatternReaderContext {
        switch source {
        case let .library(context):
            guard let usageID = context.usageID,
                  let projectID = context.projectID else {
                return context
            }
            return .project(
                patternID: context.patternID,
                usageID: usageID,
                projectID: projectID,
                projectIsCompleted: store.project(id: projectID)?.isCompleted ?? true
            )
        case let .legacy(projectID, patternID):
            return .project(
                patternID: patternID,
                usageID: patternID,
                projectID: projectID,
                projectIsCompleted: store.project(id: projectID)?.isCompleted ?? true
            )
        }
    }

    private var content: PatternReaderContent? {
        switch source {
        case let .library(context):
            guard let pattern = store.patterns.first(where: { $0.id == context.patternID }),
                  let asset = store.patternAssets.first(where: { $0.id == pattern.assetID }),
                  let url = try? store.patternAssetURL(patternID: pattern.id) else {
                return nil
            }
            return .init(displayName: pattern.displayName, kind: asset.kind, url: url)
        case let .legacy(projectID, patternID):
            guard let pattern = store.project(id: projectID)?.patterns.first(where: { $0.id == patternID }) else {
                return nil
            }
            return .init(
                displayName: pattern.displayName,
                kind: pattern.kind,
                url: store.patternURL(projectID: projectID, pattern: pattern)
            )
        }
    }

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
                if let content, FileManager.default.fileExists(atPath: content.url.path) {
                    VStack(spacing: 0) {
                        PatternMarkupToolbar(
                            document: $markup,
                            tool: $markupTool,
                            color: $markupColor,
                            width: $markupWidth,
                            onClear: { confirmingMarkupClear = true },
                            onDone: finishMarkup
                        )
                        .opacity(markupMode ? 1 : 0)
                        .allowsHitTesting(markupMode && context.canWrite)
                        .accessibilityHidden(!markupMode)
                        .frame(height: PatternMarkupToolbar.stableHeight)

                        GeometryReader { proxy in
                            let layout = PatternReaderLayoutPolicy.resolve(
                                isPad: readerIsPad,
                                width: proxy.size.width,
                                height: proxy.size.height
                            )
                            VStack(spacing: 0) {
                                readerCanvas(content: content, layout: layout)
                                if content.kind == .pdf,
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
                    switch source {
                    case let .legacy(projectID, patternID):
                        ContentUnavailableView {
                            Label("patterns.missing", systemImage: "exclamationmark.triangle")
                        } actions: {
                            Button("patterns.removeRecord", role: .destructive) {
                                try? store.deletePattern(projectID: projectID, id: patternID)
                                dismiss()
                            }
                        }
                    case .library:
                        ContentUnavailableView {
                            Label("patterns.missing", systemImage: "exclamationmark.triangle")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.ok") {
                        if save() { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("patterns.highlight", isOn: $state.highlightEnabled)
                        .disabled(!context.canWrite)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("patterns.highlightMode", selection: $state.highlightMode) {
                            Text("patterns.highlight.horizontal").tag(HighlightMode.horizontal)
                            Text("patterns.highlight.vertical").tag(HighlightMode.vertical)
                            Text("patterns.highlight.cross").tag(HighlightMode.cross)
                        }
                    } label: {
                        Label("patterns.highlightMode", systemImage: "scope")
                    }
                    .disabled(!context.canWrite)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("patterns.markup", systemImage: "pencil.and.outline") {
                        guard context.canWrite else { return }
                        markupMode.toggle()
                    }
                    .disabled(!context.canWrite)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingPageNoteIndex = state.pageIndex
                        originalPageNote = state.pageNote
                        showingPageNote = true
                    } label: {
                        Label(
                            "patterns.pageNote",
                            systemImage: state.pageNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "doc.text"
                                : "doc.text.fill"
                        )
                    }
                }
            }
            .alert("patterns.invalid", isPresented: $loadError) { Button("common.ok") { dismiss() } }
            .alert("error.saveFailed", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("common.ok") {}
            } message: {
                Text(saveError ?? "")
            }
            .sheet(isPresented: $showingPageNote, onDismiss: reloadSavedPageNote) {
                if context.canWrite {
                    EditPatternPageNoteView(pageNumber: state.pageIndex + 1, text: $state.pageNote) {
                        savePageNoteDirectly()
                    } onCancel: {
                        state.setPageNote(originalPageNote)
                    }
                } else {
                    PatternPageNoteReadOnlyView(pageNumber: state.pageIndex + 1, text: state.pageNote)
                }
            }
            .sheet(item: $managingCounter) { counter in
                EditCounterNameView(counter: counter) { name, value in
                    updateCounter(counter, name: name, value: value)
                }
            }
            .confirmationDialog("patterns.markup.clear.confirm", isPresented: $confirmingMarkupClear) {
                Button("patterns.markup.clear", role: .destructive) {
                    guard context.canWrite else { return }
                    markup.clear()
                }
                Button("common.cancel", role: .cancel) {}
            }
        }
        .tint(WatercolorTheme.actionBerry)
        .interactiveDismissDisabled()
        .onAppear {
            loadContextStateIfNeeded()
            if expectedDataGeneration == nil { expectedDataGeneration = store.dataGeneration }
            loadMarkup(page: state.pageIndex)
        }
        .onDisappear {
            guard context.canWrite else { return }
            saveMarkup(page: state.pageIndex)
            _ = save()
        }
        .onChange(of: state.pageIndex) { oldPage, newPage in
            if context.canWrite { saveMarkup(page: oldPage) }
            loadMarkup(page: newPage)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, context.canWrite else { return }
            saveMarkup(page: state.pageIndex)
            _ = save()
        }
    }

    @ViewBuilder
    private func readerCanvas(content: PatternReaderContent, layout: PatternReaderLayoutPolicy) -> some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if content.kind == .pdf {
                    PDFReaderView(
                        url: content.url,
                        navigator: pdfNavigator,
                        scaleMode: layout.pdfScaleMode,
                        state: $state,
                        pageCount: $pageCount,
                        loadError: $loadError,
                        onReady: onStoreScreenshotReady
                    )
                    .allowsHitTesting(!markupMode)
                } else {
                    ImageReaderView(url: content.url, state: $state, loadError: $loadError)
                        .allowsHitTesting(!markupMode)
                }
                if state.highlightEnabled {
                    HighlightOverlay(
                        mode: state.highlightMode,
                        horizontalPosition: $state.highlightPosition,
                        verticalPosition: $state.verticalHighlightPosition
                    )
                    .allowsHitTesting(context.canWrite && !markupMode)
                }
                if markupMode, context.canWrite {
                    PatternMarkupOverlay(
                        document: $markup,
                        tool: markupTool,
                        color: markupColor,
                        width: markupWidth
                    )
                }
            }
            .padding(.trailing, counterRailSafeAreaWidth)
            .accessibilityLabel(Text(content.displayName))

            if let projectID = context.projectID,
               let project = store.project(id: projectID),
               !markupMode {
                PatternReaderControls(
                    counters: project.counters,
                    isEnabled: context.canWrite,
                    pageIndex: state.pageIndex,
                    pageCount: content.kind == .pdf ? pageCount : 0,
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

    private func loadContextStateIfNeeded() {
        guard !didLoadContextState else { return }
        defer { didLoadContextState = true }
        guard case .library = source,
              let usageID = context.usageID,
              let projectID = context.projectID,
              let usage = store.patternUsages.first(where: {
                  $0.id == usageID && $0.patternID == context.patternID && $0.projectID == projectID
              }) else {
            return
        }
        state = usage.readingState
    }

    @discardableResult private func save() -> Bool {
        guard context.canWrite else { return true }
        state.saveCurrentPage()
        do {
            switch source {
            case .library:
                guard let usageID = context.usageID else { return true }
                try store.updatePatternState(
                    usageID: usageID,
                    state: state,
                    expectedDataGeneration: expectedDataGeneration
                )
            case let .legacy(projectID, patternID):
                try store.updatePatternState(
                    projectID: projectID,
                    id: patternID,
                    state: state,
                    expectedDataGeneration: expectedDataGeneration
                )
            }
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func incrementCounter(_ counterID: UUID) {
        guard context.canWrite, let projectID = context.projectID else { return }
        do {
            try store.selectCounter(projectID: projectID, counterID: counterID)
            try store.incrementCounter(projectID: projectID, counterID: counterID)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func updateCounter(_ counter: ProjectCounter, name: String, value: Int) {
        guard context.canWrite, let projectID = context.projectID else { return }
        do {
            try store.updateCounter(projectID: projectID, counterID: counter.id, name: name, value: value)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func navigatePDF(by delta: Int) {
        guard pageCount > 0 else { return }
        let target = min(pageCount - 1, max(0, state.pageIndex + delta))
        guard target != state.pageIndex else { return }
        pdfNavigator.go(to: target)
    }

    private func savePageNoteDirectly() {
        guard context.canWrite else { return }
        let text = state.pageNote
        do {
            switch source {
            case .library:
                guard let usageID = context.usageID else { return }
                try store.savePatternPageNote(
                    usageID: usageID,
                    pageIndex: editingPageNoteIndex,
                    text: text,
                    expectedDataGeneration: expectedDataGeneration
                )
            case let .legacy(projectID, patternID):
                try store.savePatternPageNote(
                    projectID: projectID,
                    patternID: patternID,
                    pageIndex: editingPageNoteIndex,
                    text: text,
                    expectedDataGeneration: expectedDataGeneration
                )
            }
            if editingPageNoteIndex == state.pageIndex { state.setPageNote(text) }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func reloadSavedPageNote() {
        guard editingPageNoteIndex == state.pageIndex else { return }
        switch source {
        case .library:
            guard let usageID = context.usageID,
                  let saved = store.patternUsages.first(where: { $0.id == usageID })?.readingState.pageStates[editingPageNoteIndex]?.note else {
                return
            }
            state.setPageNote(saved)
        case let .legacy(projectID, patternID):
            guard let saved = store.project(id: projectID)?.patterns.first(where: { $0.id == patternID })?.pageStates[editingPageNoteIndex]?.note else {
                return
            }
            state.setPageNote(saved)
        }
    }

    private func loadMarkup(page: Int) {
        do {
            switch source {
            case .library:
                guard let usageID = context.usageID else {
                    markup = PatternMarkupDocument()
                    return
                }
                markup = try store.loadPatternMarkup(usageID: usageID, pageIndex: page)
            case let .legacy(projectID, patternID):
                markup = try store.loadPatternMarkup(projectID: projectID, patternID: patternID, pageIndex: page)
            }
        } catch {
            markup = PatternMarkupDocument()
            if context.usageID != nil { saveError = error.localizedDescription }
        }
    }

    private func saveMarkup(page: Int) {
        guard context.canWrite, let expectedDataGeneration else { return }
        do {
            switch source {
            case .library:
                guard let usageID = context.usageID else { return }
                try store.savePatternMarkup(
                    markup,
                    usageID: usageID,
                    pageIndex: page,
                    expectedDataGeneration: expectedDataGeneration
                )
            case let .legacy(projectID, patternID):
                try store.savePatternMarkup(
                    markup,
                    projectID: projectID,
                    patternID: patternID,
                    pageIndex: page,
                    expectedDataGeneration: expectedDataGeneration
                )
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func finishMarkup() {
        guard context.canWrite else { return }
        saveMarkup(page: state.pageIndex)
        markupMode = false
    }
}

private struct PatternPageNoteReadOnlyView: View {
    @Environment(\.dismiss) private var dismiss
    let pageNumber: Int
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle(String(format: String(localized: "patterns.pageNote.page"), pageNumber))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.ok") { dismiss() }
                }
            }
        }
        .tint(WatercolorTheme.actionBerry)
    }
}

enum PatternReaderStorePresentation: Equatable {
    case standard
    case highlight
    case crossHighlight
    case markup
    case notes
}
