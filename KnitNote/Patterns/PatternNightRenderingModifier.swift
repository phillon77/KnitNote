import SwiftUI

struct PatternNightRenderingModifier: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content
                .colorInvert()
                .hueRotation(.degrees(180))
        } else {
            content
        }
    }
}

extension View {
    func patternNightRendering(active: Bool) -> some View {
        modifier(PatternNightRenderingModifier(isActive: active))
    }
}
