import SwiftUI
import OSLog

struct StoreScreenshotRootView: View {
    @EnvironmentObject private var store: JSONProjectStore
    let scene: StoreScreenshotScene
    let readinessToken: String

    var body: some View {
        Group {
            switch scene {
            case .projects:
                ProjectsView()
            case .counters:
                projectScene(kind: .counters)
            case .patternHighlight:
                patternScene(presentation: .highlight)
            case .patternCrossHighlight:
                patternScene(presentation: .crossHighlight)
            case .patternMarkup:
                patternScene(presentation: .markup)
            case .patternNotes:
                patternScene(presentation: .notes)
            case .journal:
                projectScene(kind: .journal)
            case .yarn:
                YarnLibraryView()
            case .calculators:
                NavigationStack { KnittingCalculatorsView() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("Ready")
                .font(.caption2)
                .opacity(0.01)
                .accessibilityIdentifier("storeScreenshot.ready")
        }
        .onAppear {
            Logger(subsystem: "com.phillon.KnitNote", category: "StoreScreenshots")
                .notice("storeScreenshot.ready.\(readinessToken, privacy: .public)")
        }
    }

    @ViewBuilder
    private func patternScene(presentation: PatternReaderStorePresentation) -> some View {
        if let project = store.projects.first, let pattern = project.patterns.first {
            PatternReaderView(
                projectID: project.id,
                pattern: pattern,
                storePresentation: presentation
            )
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func projectScene(kind: ProjectSceneKind) -> some View {
        if let project = store.projects.first {
            NavigationStack {
                ZStack {
                    WatercolorBackground()
                    ScrollView {
                        VStack(spacing: 20) {
                            ProjectPhotoView(url: store.photoURL(for: project))
                                .frame(width: 104, height: 104)
                                .clipShape(.rect(cornerRadius: 24))
                            switch kind {
                            case .counters:
                                WatercolorCard {
                                    CounterSelectorGrid(
                                        counters: project.counters,
                                        selectedCounterID: project.selectedCounterID,
                                        isEnabled: true,
                                        onIncrement: { _ in },
                                        onManage: { _ in }
                                    )
                                }
                            case .journal:
                                WatercolorCard {
                                    ProjectJournalSection(
                                        project: project,
                                        thumbnailURL: store.journalThumbnailURL(for:),
                                        onAdd: {},
                                        onOpen: { _ in }
                                    )
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle(project.name)
            }
        } else {
            ProgressView()
        }
    }
}

private enum ProjectSceneKind {
    case counters
    case journal
}
