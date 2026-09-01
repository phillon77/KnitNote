import Foundation

enum KnittingReminderSummary {
    static func kind(_ kind: KnittingReminderKind, locale: Locale) -> String {
        switch kind {
        case .increase:
            localized("knittingReminder.kind.increase", locale: locale)
        case .decrease:
            localized("knittingReminder.kind.decrease", locale: locale)
        case .changeYarn:
            localized("knittingReminder.kind.changeYarn", locale: locale)
        case .cable:
            localized("knittingReminder.kind.cable", locale: locale)
        case .buttonhole:
            localized("knittingReminder.kind.buttonhole", locale: locale)
        case .measure:
            localized("knittingReminder.kind.measure", locale: locale)
        case .custom:
            localized("knittingReminder.kind.custom", locale: locale)
        }
    }

    static func rule(_ rule: KnittingReminderRule, locale: Locale) -> String {
        switch rule {
        case let .oneTime(target):
            return LocaleAwareText.format("knittingReminder.rule.oneTime", locale: locale, target)
        case let .repeating(firstTarget, interval, limit):
            if let limit {
                return LocaleAwareText.format(
                    "knittingReminder.rule.repeating.limited",
                    locale: locale,
                    firstTarget,
                    interval,
                    limit
                )
            }
            return LocaleAwareText.format(
                "knittingReminder.rule.repeating",
                locale: locale,
                firstTarget,
                interval
            )
        }
    }

    static func nextTarget(_ target: Int?, locale: Locale) -> String {
        guard let target else {
            return localized("knittingReminder.next.none", locale: locale)
        }
        return LocaleAwareText.format("knittingReminder.next", locale: locale, target)
    }

    static func state(_ state: KnittingReminderState, locale: Locale) -> String {
        let key = switch state {
        case .active: "knittingReminder.state.active"
        case .completed: "knittingReminder.state.completed"
        case .stopped: "knittingReminder.state.stopped"
        }
        return localized(key, locale: locale)
    }

    static func secondaryCounter(_ name: String, locale: Locale) -> String {
        LocaleAwareText.format("knittingReminder.secondaryCounter", locale: locale, name)
    }

    static func error(_ error: Error, locale: Locale) -> String {
        if let reminderError = error as? KnittingReminderMutationError {
            let key = switch reminderError {
            case .invalidDraft, .alreadyDeferred, .invalidAction,
                 .arithmeticOverflow, .revisionExhausted,
                 .newReminderRequiresMainCounter:
                "knittingReminder.error.invalid"
            case .staleRevision:
                "knittingReminder.error.stale"
            case .occurrenceNotFound:
                "knittingReminder.error.unavailable"
            }
            return localized(key, locale: locale)
        }
        if let storeError = error as? ProjectStoreError,
           storeError == .accessRestricted {
            return localized("knittingReminder.error.accessRestricted", locale: locale)
        }
        if let libraryError = error as? PatternLibraryMutationError,
           libraryError == .projectNotFound {
            return localized("knittingReminder.error.unavailable", locale: locale)
        }
        return localized("knittingReminder.error.save", locale: locale)
    }

    private static func localized(_ key: String, locale: Locale) -> String {
        LocaleAwareText.string(key, locale: locale)
    }
}
