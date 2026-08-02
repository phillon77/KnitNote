import SwiftUI

struct PatternNightRenderingModifier: ViewModifier {
    let configuration: PatternNightRenderingConfiguration

    func body(content: Content) -> some View {
        ZStack {
            Color.white
                .opacity(configuration.pageSurfaceOpacity)
            content
            Color.white
                .blendMode(.difference)
                .opacity(configuration.differenceOverlayOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .hueRotation(.degrees(configuration.hueRotationDegrees))
    }
}

extension View {
    func patternNightRendering(active: Bool) -> some View {
        modifier(PatternNightRenderingModifier(
            configuration: PatternNightRenderingConfiguration(isActive: active)
        ))
    }
}
