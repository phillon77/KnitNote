import Testing
@testable import KnitNoteCore

@Suite @MainActor struct PatternSystemAppearanceContractTests {
    @Test func interfaceStylesMapToTheReaderAppearance() {
        #expect(PatternSystemAppearanceResolver.appearance(for: .unspecified) == .unresolved)
        #expect(PatternSystemAppearanceResolver.appearance(for: .light) == .light)
        #expect(PatternSystemAppearanceResolver.appearance(for: .dark) == .dark)
    }

    @Test func foregroundSceneWinsOverEarlierInactiveScenes() {
        let appearance = PatternSystemAppearanceResolver.resolve(scenes: [
            PatternSystemAppearanceScene(style: .dark, isForegroundActive: false),
            PatternSystemAppearanceScene(style: .light, isForegroundActive: true),
            PatternSystemAppearanceScene(style: .dark, isForegroundActive: true),
        ])

        #expect(appearance == .light)
    }

    @Test func firstSceneIsTheFallbackWhenNoneIsForegroundActive() {
        #expect(PatternSystemAppearanceResolver.resolve(scenes: [
            PatternSystemAppearanceScene(style: .dark, isForegroundActive: false),
            PatternSystemAppearanceScene(style: .light, isForegroundActive: false),
        ]) == .dark)
        #expect(PatternSystemAppearanceResolver.resolve(scenes: []) == .unresolved)
    }

    @Test func observationPublishesTheInjectedResolverOnStartAndSignal() {
        let resolverState = AppearanceResolverState(appearance: .light)
        var signal: (@MainActor () -> Void)?
        var publications: [PatternSystemAppearance] = []
        let observation = PatternSystemAppearanceObservation(
            resolve: { resolverState.appearance },
            installObservation: { refresh in
                signal = refresh
                return {}
            },
            publish: { publications.append($0) }
        )

        observation.start()
        #expect(observation.appearance == .light)
        #expect(publications == [.light])

        resolverState.appearance = .dark
        signal?()
        #expect(observation.appearance == .dark)
        #expect(publications == [.light, .dark])
    }

    @Test func repeatedStartInstallsOnceAndStopTearsDownOnce() {
        var installs = 0
        var removals = 0
        var resolutions = 0
        var signal: (@MainActor () -> Void)?
        let observation = PatternSystemAppearanceObservation(
            resolve: {
                resolutions += 1
                return .light
            },
            installObservation: { refresh in
                installs += 1
                signal = refresh
                return { removals += 1 }
            },
            publish: { _ in }
        )

        observation.start()
        observation.start()
        #expect(installs == 1)
        #expect(resolutions == 2)

        observation.stop()
        observation.stop()
        #expect(removals == 1)

        signal?()
        #expect(resolutions == 2)

        observation.start()
        #expect(installs == 2)
        #expect(resolutions == 3)
    }

    @Test func probeFilterInvokesItsCallbackOnlyForAStyleChange() {
        var callbacks = 0

        PatternSystemAppearanceChangeFilter.notifyIfChanged(
            from: .light,
            to: .light
        ) { callbacks += 1 }
        #expect(callbacks == 0)

        PatternSystemAppearanceChangeFilter.notifyIfChanged(
            from: .light,
            to: .dark
        ) { callbacks += 1 }
        #expect(callbacks == 1)

        PatternSystemAppearanceChangeFilter.notifyIfChanged(
            from: .unspecified,
            to: .light
        ) { callbacks += 1 }
        #expect(callbacks == 2)
    }
}

@MainActor
private final class AppearanceResolverState {
    var appearance: PatternSystemAppearance

    init(appearance: PatternSystemAppearance) {
        self.appearance = appearance
    }
}
