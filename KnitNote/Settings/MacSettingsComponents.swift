import SwiftUI

struct MacSettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(WatercolorTheme.actionBerry)

                content
            }
        }
    }
}

struct MacSettingsRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(
                maxWidth: .infinity,
                minHeight: CGFloat(MacSettingsLayout.minimumRowHeight),
                alignment: .leading
            )
            .contentShape(.rect)
    }
}
