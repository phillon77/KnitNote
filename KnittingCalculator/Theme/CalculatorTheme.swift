import SwiftUI

enum CalculatorTheme {
    static let ink = Color(red: 0.20, green: 0.17, blue: 0.25)
    static let berry = Color(red: 0.43, green: 0.29, blue: 0.61)
    static let lavender = Color(red: 0.76, green: 0.67, blue: 0.91)
    static let sky = Color(red: 0.73, green: 0.83, blue: 0.98)
    static let blush = Color(red: 0.96, green: 0.87, blue: 0.94)
}

struct CalculatorWatercolorBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            GeometryReader { proxy in
                ZStack {
                    RadialGradient(
                        colors: [CalculatorTheme.sky.opacity(0.38), .clear],
                        center: .topLeading,
                        startRadius: 8,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                    )

                    RadialGradient(
                        colors: [CalculatorTheme.blush.opacity(0.32), .clear],
                        center: .bottomTrailing,
                        startRadius: 8,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.65
                    )

                    RadialGradient(
                        colors: [CalculatorTheme.lavender.opacity(0.22), .clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.45
                    )
                }
                .accessibilityHidden(true)
            }
            .ignoresSafeArea()
        }
    }
}

struct CalculatorCard<Content: View>: View {
    @ViewBuilder private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(CalculatorTheme.lavender.opacity(0.45), lineWidth: 1)
            }
    }
}

/// A neutral reserved home-card slot. Task 7 replaces its contents with KnitNote routing.
struct KnitNotePromotionCard: View {
    var body: some View {
        CalculatorCard {
            Color.clear
                .frame(minHeight: 44)
        }
        .accessibilityHidden(true)
    }
}
