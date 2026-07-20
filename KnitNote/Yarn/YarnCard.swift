import SwiftUI

struct YarnCard: View {
    @Environment(\.locale) private var locale
    let yarn: StoredYarn
    let photoURL: URL?

    var body: some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 10) {
                YarnPhotoView(url: photoURL)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipped()
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))

                Text(yarn.name)
                    .font(.headline)
                    .foregroundStyle(WatercolorTheme.ink)
                    .multilineTextAlignment(.leading)

                if let color = yarn.color {
                    Text(color)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                YarnInventoryText(yarn: yarn)
                    .font(.caption)
                    .foregroundStyle(WatercolorTheme.actionBerry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        let separator = locale.identifier.hasPrefix("zh") ? "，" : ", "
        let punctuation = locale.identifier.hasPrefix("zh") ? "：" : ": "
        let color = yarn.color.map {
            "\(separator)\(String(localized: "yarn.color", locale: locale))\(punctuation)\($0)"
        } ?? ""
        let inventory = YarnInventoryText.description(for: yarn, locale: locale).map { separator + $0 } ?? ""
        let format = String(localized: "yarn.accessibility.card", locale: locale)
        return Text(verbatim: String(format: format, locale: locale, yarn.name, color, inventory))
    }
}
