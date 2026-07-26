import SwiftUI

struct ProjectCoverView: View {
    @EnvironmentObject private var store: JSONProjectStore
    let project: StoredProject
    @State private var resolvedURL: URL?

    var body: some View {
        ProjectPhotoView(url: resolvedURL)
            .id(revision)
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
            firstActiveUsageID: firstActiveUsage?.id,
            assetID: firstActiveUsage
                .flatMap { usage in store.patterns.first { $0.id == usage.patternID } }
                .map(\.assetID),
            projectCoverGeneration: store.projectCoverGeneration
        )
    }

    private var firstActiveUsage: PatternProjectUsage? {
        store.patternUsages
            .filter { $0.projectID == project.id && $0.isActive }
            .sorted {
                $0.sortOrder == $1.sortOrder
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.sortOrder < $1.sortOrder
            }
            .first
    }
}

private struct ProjectCoverRevision: Hashable {
    let photoFilename: String?
    let firstActiveUsageID: UUID?
    let assetID: UUID?
    let projectCoverGeneration: UInt64
}
