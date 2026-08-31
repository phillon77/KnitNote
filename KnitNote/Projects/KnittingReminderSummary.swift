import Foundation

enum KnittingReminderSummary {
    static func kind(_ kind: KnittingReminderKind, locale: Locale) -> String {
        switch kind {
        case .increase:
            localized("knittingReminder.kind.increase", fallback: "Increase", locale: locale)
        case .decrease:
            localized("knittingReminder.kind.decrease", fallback: "Decrease", locale: locale)
        case .changeYarn:
            localized("knittingReminder.kind.changeYarn", fallback: "Change yarn", locale: locale)
        case .cable:
            localized("knittingReminder.kind.cable", fallback: "Cable", locale: locale)
        case .buttonhole:
            localized("knittingReminder.kind.buttonhole", fallback: "Buttonhole", locale: locale)
        case .measure:
            localized("knittingReminder.kind.measure", fallback: "Measure", locale: locale)
        case .custom:
            localized("knittingReminder.kind.custom", fallback: "Custom", locale: locale)
        }
    }

    static func rule(_ rule: KnittingReminderRule, locale: Locale) -> String {
        switch rule {
        case let .oneTime(target):
            return "\(localized("knittingReminder.rule.oneTime", fallback: "One time at row", locale: locale)) \(target.formatted(.number.locale(locale)))"
        case let .repeating(firstTarget, interval, limit):
            let first = firstTarget.formatted(.number.locale(locale))
            let every = interval.formatted(.number.locale(locale))
            if let limit {
                return "\(localized("knittingReminder.rule.repeating", fallback: "From row", locale: locale)) \(first), \(localized("knittingReminder.rule.every", fallback: "every", locale: locale)) \(every) \(localized("knittingReminder.rule.rows", fallback: "rows", locale: locale)), \(limit.formatted(.number.locale(locale))) \(localized("knittingReminder.rule.times", fallback: "times", locale: locale))"
            }
            return "\(localized("knittingReminder.rule.repeating", fallback: "From row", locale: locale)) \(first), \(localized("knittingReminder.rule.every", fallback: "every", locale: locale)) \(every) \(localized("knittingReminder.rule.rows", fallback: "rows", locale: locale))"
        }
    }

    static func nextTarget(_ target: Int?, locale: Locale) -> String {
        guard let target else {
            return localized("knittingReminder.next.none", fallback: "No next row", locale: locale)
        }
        return "\(localized("knittingReminder.next", fallback: "Next row", locale: locale)) \(target.formatted(.number.locale(locale)))"
    }

    private static func localized(_ key: String, fallback: String, locale: Locale) -> String {
        let copy = LocaleAwareText.string(key, locale: locale)
        return copy == key ? fallback : copy
    }
}
