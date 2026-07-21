import SwiftUI

struct WatchCounterView: View {
    @ObservedObject var coordinator: WatchSyncCoordinator
    @State private var project = KnittingProject(name: String(localized: "sample.projectName"))

    var body: some View {
        VStack {
            Text(project.name).font(.caption)
            Text(project.currentRow, format: .number).font(.system(size: 46, weight: .bold, design: .rounded))
            Button { project.completeRow() } label: {
                Label("project.completeRow", systemImage: "plus")
            }
            Button("project.undo") { project.undoRow() }
                .disabled(project.currentRow == 0)
        }
    }
}
