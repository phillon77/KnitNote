import SwiftUI

struct ProjectCoverView: View {
    @EnvironmentObject private var store: JSONProjectStore
    let project: StoredProject
    @State private var resolvedURL: URL?

    var body: some View {
        ProjectPhotoView(url: resolvedURL)
            .task(id: revision) {
                resolvedURL = store.photoURL(for: project)
                guard !Task.isCancelled else { return }
                if resolvedURL == nil {
                    let fallbackURL = await store.projectCoverURL(for: project)
                    guard !Task.isCancelled else { return }
                    resolvedURL = fallbackURL
                }
            }
    }

    private var revision: ProjectCoverRevision {
        ProjectCoverRevision(
            photoFilename: project.photoFilename,
            firstPatternID: project.patterns.first?.id,
            generation: store.projectCoverGeneration
        )
    }
}

private struct ProjectCoverRevision: Hashable {
    let photoFilename: String?
    let firstPatternID: UUID?
    let generation: UInt64
}
