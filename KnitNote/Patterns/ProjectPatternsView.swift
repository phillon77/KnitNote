import SwiftUI
import UniformTypeIdentifiers

struct ProjectPatternsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var importing = false
    @State private var selectedPattern: PatternDocument?
    @State private var pendingDeletion: PatternDocument?
    @State private var errorMessage: String?
    private let files = PatternFileService.live()
    var body: some View { NavigationStack { List(store.project(id: projectID)?.patterns ?? []) { pattern in
        Button { selectedPattern = pattern } label: { Label(pattern.displayName, systemImage: pattern.kind == .pdf ? "doc.richtext" : "photo") }
            .swipeActions { Button("common.delete", role: .destructive) { pendingDeletion = pattern } }
    }.navigationTitle("patterns.title").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("common.ok") { dismiss() } }
        ToolbarItem(placement: .primaryAction) { Button("patterns.add", systemImage: "plus") { importing = true } }
    }.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf,.png,.jpeg,.heic]) { result in
        guard case .success(let url) = result else { return }; let access=url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        var copied: PatternDocument?
        do { let pattern = try files.importFile(from: url, projectID: projectID); copied=pattern; try store.addPattern(projectID: projectID, pattern: pattern) }
        catch { if let copied { try? files.delete(projectID:projectID,pattern:copied) }; errorMessage = error.localizedDescription }
    }.patternReaderPresentation(item: $selectedPattern) { PatternReaderView(projectID: projectID, pattern: $0) }
      .confirmationDialog("patterns.delete.title", isPresented: Binding(get:{pendingDeletion != nil},set:{if !$0{pendingDeletion=nil}})) {
        Button("common.delete", role:.destructive) { deletePending() }; Button("common.cancel",role:.cancel){pendingDeletion=nil}
      }
      .alert("patterns.error", isPresented: Binding(get:{errorMessage != nil},set:{if !$0{errorMessage=nil}})) { Button("common.ok"){} } message:{Text(errorMessage ?? "")}
    } }

    private func deletePending() {
        guard let pattern=pendingDeletion else{return}
        do { try store.deletePattern(projectID:projectID,id:pattern.id); try? files.delete(projectID:projectID,pattern:pattern) }
        catch { errorMessage=error.localizedDescription }
        pendingDeletion=nil
    }
}
