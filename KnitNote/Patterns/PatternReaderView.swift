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
                        if pattern.kind == .pdf, pageCount > 0 {
                            VStack {
                                Spacer()
                                HStack {
                                    Button {
                                        state.movePDFPage(by: -1, pageCount: pageCount)
                                    } label: {
                                        Label("patterns.previousPage", systemImage: "chevron.left")
                                    }
                                    .disabled(state.pageIndex == 0)
                                    Spacer()
                                    Text(verbatim: "\(state.pageIndex + 1) / \(pageCount)")
                                        .font(.caption.monospacedDigit())
                                    Spacer()
                                    Button {
                                        state.movePDFPage(by: 1, pageCount: pageCount)
                                    } label: {
                                        Label("patterns.nextPage", systemImage: "chevron.right")
                                    }
                                    .disabled(state.pageIndex >= pageCount - 1)
                                }
                                .labelStyle(.iconOnly)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.regularMaterial, in: Capsule())
                                .padding()
                            }
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
            }
            .alert("patterns.invalid", isPresented: $loadError) { Button("common.ok") { dismiss() } }
            .alert("error.saveFailed", isPresented: Binding(get:{saveError != nil},set:{if !$0{saveError=nil}})) { Button("common.ok"){} } message:{Text(saveError ?? "")}
        }
        .interactiveDismissDisabled()
        .onDisappear { _ = save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { _ = save() } }
    }

    @discardableResult private func save() -> Bool {
        do { try store.updatePatternState(projectID: projectID, id: patternID, state: state); return true }
        catch { saveError=error.localizedDescription; return false }
    }
}
