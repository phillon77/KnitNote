import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderAppearancePresentationTests {
    @Test func renderingConfigurationUsesOpaqueWhitePageSurfaceAndParameterizedEffects() {
        let original = PatternNightRenderingConfiguration(isActive: false)
        let night = PatternNightRenderingConfiguration(isActive: true)

        #expect(original.pageSurfaceColor == .white)
        #expect(original.pageSurfaceOpacity == 1)
        #expect(original.differenceOverlayOpacity == 0)
        #expect(original.hueRotationDegrees == 0)
        #expect(night.pageSurfaceColor == .white)
        #expect(night.pageSurfaceOpacity == 1)
        #expect(night.differenceOverlayOpacity == 1)
        #expect(night.hueRotationDegrees == 180)
    }

    @Test func unresolvedAppearanceUsesOriginalDocumentAndLightReaderPresentation() {
        let presentation = PatternReaderAppearancePresentation(
            systemAppearance: .unresolved,
            prefersOriginalColorsInDarkMode: false
        )

        #expect(!presentation.usesNightRendering)
        #expect(presentation.readerChrome == .light)
        #expect(presentation.toggleIntent == .showOriginalColors)
        #expect(presentation.accessibilityHint == .lightAppearance)
    }

    @Test func lightAppearanceUsesOriginalDocumentAndLightReaderPresentation() {
        let presentation = PatternReaderAppearancePresentation(
            systemAppearance: .light,
            prefersOriginalColorsInDarkMode: false
        )

        #expect(!presentation.usesNightRendering)
        #expect(presentation.readerChrome == .light)
        #expect(presentation.toggleIntent == .showOriginalColors)
        #expect(presentation.accessibilityHint == .lightAppearance)
    }

    @Test func darkAppearanceUsesNightDocumentAndDarkReaderPresentation() {
        let presentation = PatternReaderAppearancePresentation(
            systemAppearance: .dark,
            prefersOriginalColorsInDarkMode: false
        )

        #expect(presentation.usesNightRendering)
        #expect(presentation.readerChrome == .dark)
        #expect(presentation.toggleIntent == .showOriginalColors)
        #expect(presentation.accessibilityHint == .darkAppearance)
    }

    @Test(arguments: [
        PatternSystemAppearance.unresolved,
        .light,
        .dark,
    ])
    func originalColorPreferenceChangesOnlyTheDocumentAndNextToggleIntent(
        systemAppearance: PatternSystemAppearance
    ) {
        let presentation = PatternReaderAppearancePresentation(
            systemAppearance: systemAppearance,
            prefersOriginalColorsInDarkMode: true
        )

        #expect(!presentation.usesNightRendering)
        #expect(presentation.readerChrome == (systemAppearance == .dark ? .dark : .light))
        #expect(presentation.toggleIntent == .restoreNightAppearance)
        #expect(
            presentation.accessibilityHint
                == (systemAppearance == .dark ? .darkAppearance : .lightAppearance)
        )
    }
}
