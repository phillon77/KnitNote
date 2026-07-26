import SwiftUI
import UniformTypeIdentifiers

private struct ProjectPatternReaderSelection: Identifiable {
    let usage: PatternProjectUsage
    let pattern: StoredPattern
    var id: UUID { usage.id }
}

struct ProjectPatternsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var importing = false
    @State private var selectedPattern: ProjectPatternReaderSelection?
    @State private var pendingDeletion: ProjectPatternReaderSelection?
    @State private var errorMessage: String?
    var body: some View { NavigationStack { List(projectPatterns) { selection in
        Button { selectedPattern = selection } label: { Label(selection.pattern.displayName, systemImage: selection.pattern.kind == .pdf ? "doc.richtext" : "photo") }
            .swipeActions { Button("common.delete", role: .destructive) { pendingDeletion = selection } }
    }.scrollContentBackground(.hidden).background(WatercolorBackground()).navigationTitle("patterns.title").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("common.ok") { dismiss() } }
        ToolbarItem(placement: .primaryAction) { Button("patterns.add", systemImage: "plus") { importing = true } }
    }.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf,.png,.jpeg,.heic]) { result in
        guard case .success(let url) = result else { return }
        Task { @MainActor in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { _ = try await store.importPattern(from: url, projectID: projectID) }
            catch { errorMessage = error.localizedDescription }
        }
    }.patternReaderPresentation(item: $selectedPattern) { selection in
        PatternReaderView(context: .project(
            patternID: selection.pattern.id,
            usageID: selection.usage.id,
            projectID: projectID,
            projectIsCompleted: store.project(id: projectID)?.isCompleted ?? true
        ))
    }
      .confirmationDialog("patterns.delete.title", isPresented: Binding(get:{pendingDeletion != nil},set:{if !$0{pendingDeletion=nil}})) {
        Button("common.delete", role:.destructive) { deletePending() }; Button("common.cancel",role:.cancel){pendingDeletion=nil}
      }
      .alert("patterns.error", isPresented: Binding(get:{errorMessage != nil},set:{if !$0{errorMessage=nil}})) { Button("common.ok"){} } message:{Text(errorMessage ?? "")}
    }.tint(WatercolorTheme.actionBerry) }

    private func deletePending() {
        guard let selection = pendingDeletion else{return}
        do { try store.unlinkPattern(patternID: selection.pattern.id, from: projectID) }
        catch { errorMessage=error.localizedDescription }
        pendingDeletion=nil
    }

    private var projectPatterns: [ProjectPatternReaderSelection] {
        store.patternUsages.compactMap { usage in
            guard usage.projectID == projectID,
                  usage.isActive,
                  let pattern = store.patterns.first(where: { $0.id == usage.patternID }) else { return nil }
            return .init(usage: usage, pattern: pattern)
        }
    }
}
