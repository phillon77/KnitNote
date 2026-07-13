import SwiftUI
#if os(iOS)
import UIKit
#endif

struct WatercolorBackground: View {
    var body: some View {
        LinearGradient(
            colors: [WatercolorTheme.sky.opacity(0.34), WatercolorTheme.background, WatercolorTheme.lavender.opacity(0.22)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct WatercolorCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .background(WatercolorTheme.softWhite.opacity(0.92), in: .rect(cornerRadius: 24, style: .continuous))
            .shadow(color: WatercolorTheme.lavender.opacity(0.22), radius: 12, y: 5)
    }
}

struct YarnPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 20)
            .background(
                WatercolorTheme.actionBerry.opacity(configuration.isPressed ? 0.78 : 1),
                in: .capsule
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct FamilyHeroView: View {
    var body: some View {
        GeometryReader { proxy in
            let layout = familyHeroLayout(width: proxy.size.width, isPad: isPad)
            Image("FamilyKnittingHero")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: heroHeight(layout))
                .accessibilityLabel(Text("art.familyHero.accessibility"))
        }
        .frame(height: isPad ? 300 : 150)
    }

    private var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        true
        #endif
    }

    private func heroHeight(_ layout: FamilyHeroLayout) -> CGFloat {
        switch layout {
        case let .phone(height), let .wide(height): CGFloat(height)
        }
    }
}
