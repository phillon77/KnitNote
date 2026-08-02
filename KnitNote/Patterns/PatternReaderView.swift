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
    let assetID: UUID
    let url: URL
}

struct PatternReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var entitlementCoordinator: EntitlementCoordinator
    private let source: PatternReaderSource
    private let storePresentation: PatternReaderStorePresentation
    @State private var state: PatternReadingState
    @State private var readerSession: PatternReaderSession
    @State private var canvasIsActive = false
    @State private var handledPageIndex: Int?
    @State private var loadError = false
    @State private var pageCount = 0
    @State private var pdfViewport = PatternPDFViewportState()
    @State private var saveError: String?
    @State private var showingPageNote = false
    @State private var originalPageNote = ""
    @State private var editingPageNoteIndex = 0
    @State private var markupMode = false
    @State private var markup = PatternMarkupDocument()
    @State private var markupSession = PatternReaderMarkupSession()
    @State private var markupTool = PatternMarkupTool.pen
    @State private var markupColor = MarkupColor.red
    @State private var markupWidth = 0.008
    @State private var confirmingMarkupClear = false
    @State private var expectedDataGeneration: UInt64?
    @State private var revisionCoordinator = PatternReaderRevisionCoordinator(expectedDataGeneration: 0)
    @State private var pendingPageTransition: PatternReaderPageTransition?
    @State private var managingCounter: ProjectCounter?
    @StateObject private var pdfNavigator = PDFPageNavigator()
    private let counterRailSafeAreaWidth: CGFloat = 64
    private let onStoreScreenshotReady: @MainActor () -> Void

    /// Archive-level reader entry point. A library context loads state only
    /// from its usage; a standalone context begins with fresh, ephemeral state.
    init(
        context: PatternReaderContext,
        storePresentation: PatternReaderStorePresentation = .standard,
        onStoreScreenshotReady: @escaping @MainActor () -> Void = {}
    ) {
        source = .library(context)
        _state = State(initialValue: .init())
        _readerSession = State(initialValue: PatternReaderSession(context: context))
        self.storePresentation = storePresentation
        _markupMode = State(initialValue: storePresentation == .markup)
        _showingPageNote = State(initialValue: storePresentation == .notes)
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
        _state = State(initialValue: .init())
        _readerSession = State(initialValue: PatternReaderSession(context: .project(
            patternID: pattern.id,
            usageID: pattern.id,
            projectID: projectID,
            projectIsCompleted: false
        )))
        self.storePresentation = storePresentation
        _markupMode = State(initialValue: storePresentation == .markup)
        _showingPageNote = State(initialValue: storePresentation == .notes)
        self.onStoreScreenshotReady = onStoreScreenshotReady
    }

    private var sourceContext: PatternReaderContext {
        switch source {
        case let .library(context):
            return context
        case let .legacy(projectID, patternID):
            return .project(
                patternID: patternID,
                usageID: patternID,
                projectID: projectID,
                projectIsCompleted: store.project(id: projectID)?.isCompleted ?? true,
                entitlementCanWrite: entitlementCoordinator.allowsWrites
            )
        }
    }

    private var resolvedContext: PatternReaderContext {
        let base = sourceContext
        guard let usageID = base.usageID,
              let projectID = base.projectID else {
            return base
        }
        let usageIsActive: Bool
        switch source {
        case .library:
            usageIsActive = store.patternUsages.contains {
                $0.id == usageID && $0.patternID == base.patternID && $0.projectID == projectID && $0.isActive
            }
        case .legacy:
            usageIsActive = base.usageIsActive
        }
        return .project(
            patternID: base.patternID,
            usageID: usageID,
            projectID: projectID,
            usageIsActive: usageIsActive,
            projectIsCompleted: store.project(id: projectID)?.isCompleted ?? true,
            entitlementCanWrite: entitlementCoordinator.allowsWrites
        )
    }

    private var context: PatternReaderContext {
        let base = readerSession.phase == .hydrated ? readerSession.context : resolvedContext
        guard let usageID = base.usageID,
              let projectID = base.projectID else {
            return base
        }
        return .project(
            patternID: base.patternID,
            usageID: usageID,
            projectID: projectID,
            usageIsActive: base.usageIsActive,
            projectIsCompleted: store.project(id: projectID)?.isCompleted ?? true,
            entitlementCanWrite: entitlementCoordinator.allowsWrites
        )
    }

    private var highlightEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.highlightEnabled },
            set: { value in
                guard requestReaderWriteAccess() else { return }
                guard value != state.highlightEnabled else { return }
                state.highlightEnabled = value
                _ = save()
            }
        )
    }

    private var highlightModeBinding: Binding<HighlightMode> {
        Binding(
            get: { state.highlightMode },
            set: { value in
                guard requestReaderWriteAccess() else { return }
                guard value != state.highlightMode else { return }
                state.highlightMode = value
                _ = save()
            }
        )
    }

    private var horizontalHighlightBinding: Binding<Double> {
        Binding(
            get: { state.highlightPosition },
            set: { value in
                guard requestReaderWriteAccess() else { return }
                state.highlightPosition = value
            }
        )
    }

    private var verticalHighlightBinding: Binding<Double> {
        Binding(
            get: { state.verticalHighlightPosition },
            set: { value in
                guard requestReaderWriteAccess() else { return }
                state.verticalHighlightPosition = value
            }
        )
    }

    private var canvasState: Binding<PatternReadingState> {
        Binding(
            get: { state },
            set: { newState in
                guard canvasIsActive,
                      readerSession.canAcceptCanvasCallbacks,
                      readerSession.identity == readerContextIdentity else { return }
                var synchronizedState = newState
                synchronizedState.saveCurrentPage()
                if let transition = PatternReaderPageTransition(
                    previousState: pendingPageTransition?.rollbackState ?? state,
                    proposedState: synchronizedState
                ) {
                    pendingPageTransition = transition
                }
                state = synchronizedState
                _ = readerSession.acceptCanvasState(synchronizedState)
            }
        )
    }

    private var content: PatternReaderContent? {
        switch source {
        case let .library(context):
            guard let pattern = store.patterns.first(where: { $0.id == context.patternID }),
                  let asset = store.patternAssets.first(where: { $0.id == pattern.assetID }),
                  let url = try? store.patternAssetURL(patternID: pattern.id) else {
                return nil
            }
            return .init(displayName: pattern.displayName, kind: asset.kind, assetID: asset.id, url: url)
        case let .legacy(projectID, patternID):
            guard let pattern = store.project(id: projectID)?.patterns.first(where: { $0.id == patternID }) else {
                return nil
            }
            return .init(
                displayName: pattern.displayName,
                kind: pattern.kind,
                assetID: pattern.id,
                url: store.patternURL(projectID: projectID, pattern: pattern)
            )
        }
    }

    private var readerContextIdentity: PatternReaderContextIdentity {
        .init(context: resolvedContext, assetID: content?.assetID)
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
                if readerSession.phase == .hydrated,
                   readerSession.identity == readerContextIdentity,
                   let content,
                   FileManager.default.fileExists(atPath: content.url.path) {
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
                } else if readerSession.phase == .hydrated,
                          readerSession.identity == readerContextIdentity {
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
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.ok") {
                        if saveMarkup(page: state.pageIndex), saveBrowsingState() {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("patterns.highlight", isOn: highlightEnabledBinding)
                        .disabled(!(context.canWrite || context.canRequestUnlock))
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("patterns.highlightMode", selection: highlightModeBinding) {
                            Text("patterns.highlight.horizontal").tag(HighlightMode.horizontal)
                            Text("patterns.highlight.vertical").tag(HighlightMode.vertical)
                            Text("patterns.highlight.cross").tag(HighlightMode.cross)
                        }
                    } label: {
                        Label("patterns.highlightMode", systemImage: "scope")
                    }
                    .disabled(!(context.canWrite || context.canRequestUnlock))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("patterns.markup", systemImage: "pencil.and.outline") {
                        guard requestReaderWriteAccess() else { return }
                        guard readerSession.identity == readerContextIdentity else { return }
                        markupMode.toggle()
                    }
                    .disabled(!(context.canWrite || context.canRequestUnlock))
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
            .alert("patterns.reader.conflict", isPresented: Binding(
                get: { revisionCoordinator.requiresConflictResolution },
                set: { isPresented in
                    guard !isPresented, revisionCoordinator.canDismissConflictPresentation else { return }
                }
            )) {
                Button("patterns.reader.discardAndReload") {
                    discardMarkupAndReload()
                }
            } message: {
                Text("patterns.reader.conflict.message")
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
                    guard context.canWrite, readerSession.identity == readerContextIdentity else { return }
                    markup.clear()
                }
                Button("common.cancel", role: .cancel) {}
            }
        }
        .tint(WatercolorTheme.actionBerry)
        .interactiveDismissDisabled()
        .task(id: readerContextIdentity) {
            reloadReader(for: readerContextIdentity)
        }
        .onChange(of: markup) { _, updatedMarkup in
            markupSession.recordEdit(updatedMarkup)
            revisionCoordinator.setMarkupDirty(markupSession.isDirty)
        }
        .onChange(of: store.dataGeneration) { _, generation in
            handleStoreGenerationChange(generation)
        }
        .onDisappear {
            guard canvasIsActive, readerSession.canPersist else { return }
            guard context.canWrite else { return }
            guard saveMarkup(page: state.pageIndex) else { return }
            _ = saveBrowsingState()
        }
        .onChange(of: state.pageIndex) { _, newPage in
            guard canvasIsActive, readerSession.canAcceptCanvasCallbacks else { return }
            guard handledPageIndex != newPage else { return }
            guard let transition = pendingPageTransition,
                  transition.targetPageIndex == newPage else { return }
            guard revisionCoordinator.canChangePage else {
                restorePageTransition()
                saveError = String(localized: "error.saveFailed")
                return
            }
            handledPageIndex = newPage
            if context.canWrite, !saveMarkup(page: transition.rollbackPageIndex) {
                restorePageTransition()
                return
            }
            pendingPageTransition = nil
            loadMarkup(page: newPage, readerGeneration: readerSession.generation)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, canvasIsActive, readerSession.canPersist else { return }
            guard context.canWrite else { return }
            guard saveMarkup(page: state.pageIndex) else { return }
            _ = saveBrowsingState()
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
                        state: canvasState,
                        pageCount: $pageCount,
                        loadError: $loadError,
                        viewport: $pdfViewport,
                        onReady: onStoreScreenshotReady
                    )
                    .allowsHitTesting(!markupMode)
                } else {
                    ImageReaderView(url: content.url, state: canvasState, loadError: $loadError)
                        .allowsHitTesting(!markupMode)
                }
                if state.highlightEnabled {
                    HighlightOverlay(
                        mode: state.highlightMode,
                        horizontalPosition: horizontalHighlightBinding,
                        verticalPosition: verticalHighlightBinding,
                        contentRect: content.kind == .pdf ? pdfViewport.pageFrame : nil,
                        onPositionCommit: commitHighlightPositionEdit
                    )
                    .allowsHitTesting(
                        (context.canWrite || context.canRequestUnlock) && !markupMode
                    )
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
            .id(readerSession.generation)
            .padding(.trailing, counterRailSafeAreaWidth)
            .accessibilityLabel(Text(content.displayName))

            if let projectID = context.projectID,
               let project = store.project(id: projectID),
               !markupMode {
                PatternReaderControls(
                    counters: project.counters,
                    isEnabled: context.canWrite || context.canRequestUnlock,
                    pageIndex: state.pageIndex,
                    pageCount: content.kind == .pdf ? pageCount : 0,
                    showsOverlayPageControls: layout.pageControlPlacement == .overlay,
                    onPreviousPage: { navigatePDF(by: -1) },
                    onNextPage: { navigatePDF(by: 1) },
                    onIncrement: { _ = incrementCounter($0) },
                    onManage: { counterID in
                        guard requestReaderWriteAccess() else { return }
                        managingCounter = project.counters.first { $0.id == counterID }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear {
            canvasIsActive = true
            handledPageIndex = state.pageIndex
        }
    }

    private func reloadReader(for identity: PatternReaderContextIdentity) {
        guard !Task.isCancelled, identity == readerContextIdentity else { return }
        canvasIsActive = false
        handledPageIndex = nil
        pendingPageTransition = nil
        pageCount = 0
        pdfViewport = PatternPDFViewportState()
        loadError = false
        saveError = nil
        managingCounter = nil
        showingPageNote = storePresentation == .notes
        markupMode = storePresentation == .markup
        let currentContext = resolvedContext
        let hydrationContext: PatternReaderContext
        let hydrationState: PatternReadingState

        switch source {
        case .library:
            if let usageID = currentContext.usageID,
               let projectID = currentContext.projectID,
               store.patternUsages.contains(where: {
                   $0.id == usageID && $0.patternID == currentContext.patternID && $0.projectID == projectID && $0.isActive
               }) {
                hydrationContext = currentContext
                hydrationState = PatternReaderStateLoader.readingState(
                    for: currentContext,
                    usages: store.patternUsages
                )
            } else {
                hydrationContext = .readOnly(patternID: currentContext.patternID)
                hydrationState = .init()
            }
        case let .legacy(projectID, patternID):
            hydrationContext = currentContext
            var legacyState = store.project(id: projectID)?.patterns.first(where: { $0.id == patternID })?.readingState ?? .init()
            switch storePresentation {
            case .standard:
                break
            case .highlight:
                legacyState.highlightEnabled = true
                legacyState.highlightMode = .horizontal
            case .crossHighlight:
                legacyState.highlightEnabled = true
                legacyState.highlightMode = .cross
            case .markup, .notes:
                break
            }
            hydrationState = legacyState
        }
        let generation = readerSession.beginLoading(context: hydrationContext, identity: identity)
        expectedDataGeneration = store.dataGeneration
        revisionCoordinator.reset(expectedDataGeneration: store.dataGeneration)
        state = hydrationState
        markup = .init()
        markupSession.beginLoading(readerGeneration: generation, pageIndex: state.pageIndex)
        guard !Task.isCancelled,
              identity == readerContextIdentity,
              readerSession.generation == generation else { return }
        loadMarkup(page: state.pageIndex, readerGeneration: generation)
        let hydrated = readerSession.hydrate(state, for: generation)
        guard !Task.isCancelled,
              identity == readerContextIdentity,
              hydrated else { return }
    }

    private func handleStoreGenerationChange(_ generation: UInt64) {
        switch revisionCoordinator.observeStoreGeneration(generation, canWrite: resolvedContext.canWrite) {
        case .none:
            break
        case .reload, .reloadReadOnly:
            reloadReader(for: readerContextIdentity)
        case .conflict:
            saveError = String(localized: "error.saveFailed")
        }
    }

    private func discardMarkupAndReload() {
        guard revisionCoordinator.discardConflictAndPrepareReload(
            expectedDataGeneration: store.dataGeneration
        ) else { return }
        markup = .init()
        reloadReader(for: readerContextIdentity)
    }

    private func restorePageTransition() {
        guard let transition = pendingPageTransition,
              transition.targetPageIndex == state.pageIndex else { return }
        state = transition.rollbackState
        handledPageIndex = transition.rollbackState.pageIndex
        pendingPageTransition = nil
        pdfNavigator.go(to: transition.rollbackPageIndex)
    }

    private func commitHighlightPositionEdit() {
        guard requestReaderWriteAccess() else { return }
        guard canvasIsActive,
              readerSession.canPersist,
              readerSession.identity == readerContextIdentity,
              context.canWrite else { return }
        _ = save()
    }

    @discardableResult private func save() -> Bool {
        persistReadingState(isBrowsingHousekeeping: false)
    }

    @discardableResult private func saveBrowsingState() -> Bool {
        persistReadingState(isBrowsingHousekeeping: true)
    }

    private func persistReadingState(isBrowsingHousekeeping: Bool) -> Bool {
        guard readerSession.canPersist, readerSession.identity == readerContextIdentity else { return true }
        guard context.canWrite else { return true }
        state.saveCurrentPage()
        _ = readerSession.acceptCanvasState(state)
        do {
            let nextGeneration: UInt64
            switch source {
            case .library:
                guard let usageID = context.usageID else { return true }
                if isBrowsingHousekeeping {
                    nextGeneration = try store.updatePatternBrowsingState(
                        usageID: usageID,
                        state: state.browsingState,
                        expectedDataGeneration: expectedDataGeneration
                    )
                } else {
                    nextGeneration = try store.updatePatternState(
                        usageID: usageID,
                        state: state,
                        expectedDataGeneration: expectedDataGeneration
                    )
                }
            case let .legacy(projectID, patternID):
                if isBrowsingHousekeeping {
                    nextGeneration = try store.updatePatternBrowsingState(
                        projectID: projectID,
                        id: patternID,
                        state: state.browsingState,
                        expectedDataGeneration: expectedDataGeneration
                    )
                } else {
                    nextGeneration = try store.updatePatternState(
                        projectID: projectID,
                        id: patternID,
                        state: state,
                        expectedDataGeneration: expectedDataGeneration
                    )
                }
            }
            self.expectedDataGeneration = nextGeneration
            revisionCoordinator.confirmMutation(generation: nextGeneration)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func incrementCounter(_ counterID: UUID) -> Bool {
        guard requestReaderWriteAccess() else { return false }
        guard readerSession.canPersist,
              readerSession.identity == readerContextIdentity,
              context.canWrite else { return false }
        do {
            guard let usageID = context.usageID,
                  let expectedDataGeneration else { return false }
            self.expectedDataGeneration = try store.mutatePatternReaderCounter(
                usageID: usageID,
                counterID: counterID,
                mutation: .increment,
                expectedDataGeneration: expectedDataGeneration
            )
            revisionCoordinator.confirmMutation(generation: self.expectedDataGeneration ?? expectedDataGeneration)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func updateCounter(_ counter: ProjectCounter, name: String, value: Int) -> Bool {
        guard requestReaderWriteAccess() else { return false }
        guard readerSession.canPersist,
              readerSession.identity == readerContextIdentity,
              context.canWrite else { return false }
        do {
            guard let usageID = context.usageID,
                  let expectedDataGeneration else { return false }
            self.expectedDataGeneration = try store.mutatePatternReaderCounter(
                usageID: usageID,
                counterID: counter.id,
                mutation: .update(name: name, value: value),
                expectedDataGeneration: expectedDataGeneration
            )
            revisionCoordinator.confirmMutation(generation: self.expectedDataGeneration ?? expectedDataGeneration)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func navigatePDF(by delta: Int) {
        guard pageCount > 0 else { return }
        let target = min(pageCount - 1, max(0, state.pageIndex + delta))
        guard target != state.pageIndex else { return }
        pdfNavigator.go(to: target)
    }

    @discardableResult
    private func savePageNoteDirectly() -> Bool {
        guard readerSession.canPersist,
              readerSession.identity == readerContextIdentity,
              context.canWrite else { return false }
        let text = state.pageNote
        do {
            let nextGeneration: UInt64
            switch source {
            case .library:
                guard let usageID = context.usageID else { return false }
                nextGeneration = try store.savePatternPageNote(
                    usageID: usageID,
                    pageIndex: editingPageNoteIndex,
                    text: text,
                    expectedDataGeneration: expectedDataGeneration
                )
            case let .legacy(projectID, patternID):
                nextGeneration = try store.savePatternPageNote(
                    projectID: projectID,
                    patternID: patternID,
                    pageIndex: editingPageNoteIndex,
                    text: text,
                    expectedDataGeneration: expectedDataGeneration
                )
            }
            expectedDataGeneration = nextGeneration
            revisionCoordinator.confirmMutation(generation: nextGeneration)
            if editingPageNoteIndex == state.pageIndex { state.setPageNote(text) }
            return true
        } catch {
            saveError = error.localizedDescription
            return false
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

    private func loadMarkup(page: Int, readerGeneration: UInt64) {
        markupSession.beginLoading(readerGeneration: readerGeneration, pageIndex: page)
        do {
            let loadedMarkup: PatternMarkupDocument
            switch source {
            case .library:
                guard let usageID = context.usageID else {
                    loadedMarkup = .init()
                    guard readerSession.generation == readerGeneration,
                          readerSession.identity == readerContextIdentity else { return }
                    markup = loadedMarkup
                    _ = markupSession.finishLoading(loadedMarkup, for: readerGeneration, pageIndex: page)
                    return
                }
                loadedMarkup = try store.loadPatternMarkup(usageID: usageID, pageIndex: page)
            case let .legacy(projectID, patternID):
                loadedMarkup = try store.loadPatternMarkup(projectID: projectID, patternID: patternID, pageIndex: page)
            }
            guard readerSession.generation == readerGeneration,
                  readerSession.identity == readerContextIdentity else { return }
            markup = loadedMarkup
            _ = markupSession.finishLoading(loadedMarkup, for: readerGeneration, pageIndex: page)
        } catch {
            guard readerSession.generation == readerGeneration,
                  readerSession.identity == readerContextIdentity else { return }
            markup = .init()
            _ = markupSession.failLoading(for: readerGeneration, pageIndex: page)
            if context.usageID != nil { saveError = error.localizedDescription }
        }
    }

    @discardableResult
    private func saveMarkup(page: Int) -> Bool {
        guard canvasIsActive,
              readerSession.canPersist,
              readerSession.identity == readerContextIdentity,
              markupSession.canPersistMarkup(readerGeneration: readerSession.generation, pageIndex: page) else { return true }
        guard revisionCoordinator.phase == .ready,
              context.canWrite,
              let expectedDataGeneration else { return false }
        do {
            let nextGeneration: UInt64
            switch source {
            case .library:
                guard let usageID = context.usageID else { return false }
                nextGeneration = try store.savePatternMarkup(
                    markup,
                    usageID: usageID,
                    pageIndex: page,
                    expectedDataGeneration: expectedDataGeneration
                )
            case let .legacy(projectID, patternID):
                nextGeneration = try store.savePatternMarkup(
                    markup,
                    projectID: projectID,
                    patternID: patternID,
                    pageIndex: page,
                    expectedDataGeneration: expectedDataGeneration
                )
            }
            self.expectedDataGeneration = nextGeneration
            revisionCoordinator.confirmMutation(generation: nextGeneration)
            markupSession.markPersisted(readerGeneration: readerSession.generation, pageIndex: page)
            revisionCoordinator.setMarkupDirty(false)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func finishMarkup() {
        guard readerSession.canPersist,
              readerSession.identity == readerContextIdentity,
              context.canWrite else { return }
        guard saveMarkup(page: state.pageIndex) else { return }
        markupMode = false
    }

    private func requestReaderWriteAccess() -> Bool {
        if context.canWrite {
            return true
        }
        guard context.canRequestUnlock else { return false }
        _ = entitlementCoordinator.authorize(.editPatternReadingState)
        return false
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
