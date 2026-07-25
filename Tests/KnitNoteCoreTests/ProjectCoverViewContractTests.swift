import Foundation
import Testing

@Suite struct ProjectCoverViewContractTests {
    @Test func projectScreensUseOneAsyncCoverView() throws {
        let cover = try source("KnitNote/Projects/ProjectCoverView.swift")
        let card = try source("KnitNote/Projects/ProjectCard.swift")
        let detail = try source("KnitNote/Projects/ProjectDetailView.swift")
        let list = try source("KnitNote/Projects/ProjectsView.swift")
        let screenshots = try source("KnitNote/App/StoreScreenshotRootView.swift")
        let photo = try source("KnitNote/Projects/ProjectPhotoView.swift")

        #expect(cover.contains("await store.projectCoverURL(for: project)"))
        #expect(cover.contains(".task(id: revision)"))
        #expect(cover.contains("generation: store.projectCoverGeneration"))
        #expect(cover.contains("guard !Task.isCancelled else { return }"))
        #expect(cover.contains("ProjectPhotoView(url: resolvedURL)"))
        #expect(cover.contains(".id(revision)"))
        #expect(card.contains("ProjectCoverView(project: project)"))
        #expect(detail.contains("ProjectCoverView(project: project)"))
        #expect(!card.contains("let photoURL: URL?"))
        #expect(list.contains("ProjectCard(project: project)"))
        #expect(!list.contains("photoURL: store.photoURL"))
        #expect(screenshots.contains("ProjectCoverView(project: project)"))
        #expect(!screenshots.contains("ProjectPhotoView(url: store.photoURL(for: project))"))
        #expect(photo.contains("guard !Task.isCancelled else { return }"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
