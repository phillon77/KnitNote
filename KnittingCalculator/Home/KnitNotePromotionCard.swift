import SwiftUI
import UIKit

#if DEBUG
private struct KnitNotePromotionRenderObserver: @unchecked Sendable {
    let action: @MainActor () -> Void
}

private struct KnitNotePromotionRenderObserverKey: EnvironmentKey {
    static let defaultValue = KnitNotePromotionRenderObserver(action: {})
}

private extension EnvironmentValues {
    var knitNotePromotionRenderObserver: KnitNotePromotionRenderObserver {
        get { self[KnitNotePromotionRenderObserverKey.self] }
        set { self[KnitNotePromotionRenderObserverKey.self] = newValue }
    }
}

extension View {
    func onKnitNotePromotionRendered(
        perform action: @escaping @MainActor () -> Void
    ) -> some View {
        environment(
            \.knitNotePromotionRenderObserver,
            KnitNotePromotionRenderObserver(action: action)
        )
    }
}
#endif

struct KnitNotePromotionCard: View {
#if DEBUG
    @Environment(\.knitNotePromotionRenderObserver)
    private var renderObserver
#endif

    var body: some View {
        CalculatorCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("calculator.promotion.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("calculator.promotion.product.relationship")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("calculator.promotion.action") {
                    UIApplication.shared.open(KnitNoteLinkRouter.launchURL, options: [:]) { opened in
                        guard case let .openStore(storeURL) = KnitNoteLinkRouter.destination(after: opened) else {
                            return
                        }
                        UIApplication.shared.open(storeURL, options: [:])
                    }
                }
                .buttonStyle(.bordered)
                .tint(CalculatorTheme.berry)
                .frame(minHeight: 44)
                .accessibilityLabel(Text("calculator.promotion.action.accessibility"))
                .accessibilityHint(Text("calculator.promotion.action.hint"))
            }
        }
#if DEBUG
        .onAppear {
            renderObserver.action()
        }
#endif
    }
}
