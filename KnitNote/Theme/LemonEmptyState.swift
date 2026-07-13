import SwiftUI

struct LemonEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        WatercolorCard {
            VStack(spacing: 14) {
                Image("LemonYarn")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 180)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(WatercolorTheme.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(YarnPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: 420)
        }
    }
}
