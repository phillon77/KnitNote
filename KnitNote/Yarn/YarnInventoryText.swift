import Foundation
import SwiftUI

struct YarnInventoryText: View {
    @Environment(\.locale) private var locale
    let yarn: StoredYarn

    var body: some View {
        if let description = Self.description(for: yarn, locale: locale) {
            Text(verbatim: description)
        }
    }

    static func description(for yarn: StoredYarn, locale: Locale) -> String? {
        if let balls = yarn.remainingBalls {
            return description(
                format: String(localized: "yarn.inventory.balls", locale: locale),
                quantity: balls,
                locale: locale
            )
        } else if let grams = yarn.remainingGrams {
            return description(
                format: String(localized: "yarn.inventory.grams", locale: locale),
                quantity: grams,
                locale: locale
            )
        }
        return nil
    }

    private static func description(format: String, quantity: Decimal, locale: Locale) -> String {
        let quantity = quantity.formatted(Decimal.FormatStyle.number.locale(locale))
        return String(format: format, locale: locale, quantity)
    }
}
