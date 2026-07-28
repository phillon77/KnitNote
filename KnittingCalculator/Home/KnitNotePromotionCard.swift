import SwiftUI
import UIKit

struct KnitNotePromotionCard: View {
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
    }
}
