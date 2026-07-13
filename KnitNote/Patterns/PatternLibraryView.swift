import SwiftUI
import UniformTypeIdentifiers

private struct PatternLibrarySelection: Identifiable {
    let projectID: UUID
    let pattern: PatternDocument
    var id: UUID { pattern.id }
}

struct PatternLibraryView: View {
    @EnvironmentObject private var store: JSONProjectStore
    @State private var selectedPattern: PatternLibrarySelection?
    @State private var showingProjectChooser = false
    @State private var importProjectID: UUID?
    @State private var importing = false
    @State private var errorMessage: String?
    private let files = PatternFileService.live()

    var body: some View {
        NavigationStack {
            Group {
                if patternGroups(from: store.projects).isEmpty {
                    ContentUnavailableView("patterns.library.empty.title", systemImage: "doc.text.image", description: Text("patterns.library.empty.message"))
                } else {
                    List {
                        ForEach(patternGroups(from: store.projects)) { group in
                            Section(group.projectName) {
                                ForEach(group.patterns) { pattern in
                                    Button {
                                        selectedPattern = PatternLibrarySelection(projectID: group.id, pattern: pattern)
                                    } label: {
                                        Label(pattern.displayName, systemImage: pattern.kind == .pdf ? "doc.richtext" : "photo")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("nav.patterns")
            .toolbar {
                Button("patterns.add", systemImage: "plus") { showingProjectChooser = true }
                    .disabled(store.projects.isEmpty)
            }
            .patternReaderPresentation(item: $selectedPattern) { selection in
                PatternReaderView(projectID: selection.projectID, pattern: selection.pattern)
            }
            .sheet(isPresented: $showingProjectChooser) {
                ChoosePatternProjectView { projectID in
                    importProjectID = projectID
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        importing = true
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .png, .jpeg, .heic]) { result in
                importPattern(result)
            }
            .alert("patterns.error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("common.ok") {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func importPattern(_ result: Result<URL, Error>) {
        guard let projectID = importProjectID, case .success(let url) = result else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var copied: PatternDocument?
        do {
            let pattern = try files.importFile(from: url, projectID: projectID)
            copied = pattern
            try store.addPattern(projectID: projectID, pattern: pattern)
        } catch {
            if let copied { try? files.delete(projectID: projectID, pattern: copied) }
            errorMessage = error.localizedDescription
        }
    }
}
