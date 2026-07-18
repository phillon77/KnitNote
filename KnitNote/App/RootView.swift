import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RootView: View {
    @Binding var storedLanguage: String
    @EnvironmentObject private var launchExperience: LaunchExperienceCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroFrame: CGRect = .zero

    var body: some View {
        GeometryReader { geometry in
            let destinationFrame = FamilyHeroDestination.resolved(
                liveFrame: heroFrame,
                containerSize: geometry.size
            )

            ZStack {
                WatercolorTheme.softWhite
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                homeTabs
                    .opacity(launchExperience.homeOpacity)
                    .animation(
                        .easeInOut(duration: LaunchExperienceTiming.homeTransitionSeconds),
                        value: launchExperience.homeOpacity
                    )
                    .accessibilityHidden(!homeIsAccessible)
                    .allowsHitTesting(homeIsAccessible)

                if launchExperience.showsOverlay {
                    FamilyLaunchAnimationView(
                        phase: launchExperience.phase,
                        destinationFrame: destinationFrame
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .onTapGesture {
                        launchExperience.skip()
                    }
                }
            }
            .coordinateSpace(name: FamilyLaunchAnimationView.rootCoordinateSpaceName)
            .onPreferenceChange(FamilyHeroFramePreferenceKey.self) { nextFrame in
                if FamilyHeroDestination.isValid(nextFrame) {
                    heroFrame = nextFrame
                }
            }
            .task {
                launchExperience.start(reduceMotion: reduceMotion)
                if !FamilyHeroArtworkAvailability.isAvailable {
                    launchExperience.skip()
                }
            }
        }
    }

    private var homeTabs: some View {
        TabView {
            ProjectsView()
                .tabItem { Label("nav.projects", systemImage: "square.grid.2x2") }
            PatternLibraryView()
                .tabItem { Label("nav.patterns", systemImage: "doc.text.image") }
            PlaceholderView(title: "nav.yarn", symbol: "shippingbox")
                .tabItem { Label("nav.yarn", systemImage: "shippingbox") }
            SettingsView(storedLanguage: $storedLanguage)
                .tabItem { Label("nav.settings", systemImage: "gearshape") }
        }
        .tint(WatercolorTheme.actionBerry)
        .watercolorTabBar()
    }

    private var homeIsAccessible: Bool {
        launchHomeIsInteractive(phase: launchExperience.phase)
    }
}

private enum FamilyHeroArtworkAvailability {
    @MainActor
    static var isAvailable: Bool {
        #if os(iOS)
        UIImage(named: "FamilyKnittingHero") != nil
        #elseif os(macOS)
        NSImage(named: "FamilyKnittingHero") != nil
        #else
        false
        #endif
    }
}

private extension View {
    @ViewBuilder
    func watercolorTabBar() -> some View {
        #if os(iOS)
        self
            .toolbarBackground(WatercolorTheme.softWhite.opacity(0.96), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        #else
        self
        #endif
    }
}

private struct PlaceholderView: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        NavigationStack {
            ZStack {
                WatercolorBackground()
                LemonEmptyState(title: title, message: "common.comingSoon")
                    .padding()
            }
            .navigationTitle(title)
        }
    }
}
