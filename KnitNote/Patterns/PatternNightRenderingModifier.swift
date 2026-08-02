import SwiftUI

struct PatternNightRenderingModifier: ViewModifier {
    let configuration: PatternNightRenderingConfiguration

    func body(content: Content) -> some View {
        content
            .colorEffect(
                ShaderLibrary.patternNightColorInvert(),
                isEnabled: configuration.colorInvertIsEnabled
            )
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
