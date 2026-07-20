import Foundation

func projectCounterDisplayName(_ counter: ProjectCounter, locale: Locale) -> String {
    counter.customName ?? String(
        format: String(localized: "counter.defaultName", locale: locale),
        locale: locale,
        counter.defaultOrdinal
    )
}

enum CounterAccessibilityAction {
    case collapse
    case decrement
    case expand
    case increment
    case note
    case rename
}

func counterActionAccessibilityLabel(
    _ action: CounterAccessibilityAction,
    counter: ProjectCounter,
    locale: Locale
) -> String {
    let format = switch action {
    case .collapse:
        String(localized: "counter.accessibility.collapse", locale: locale)
    case .decrement:
        String(localized: "counter.accessibility.decrement", locale: locale)
    case .expand:
        String(localized: "counter.accessibility.expand", locale: locale)
    case .increment:
        String(localized: "counter.accessibility.increment", locale: locale)
    case .note:
        String(localized: "counter.accessibility.note", locale: locale)
    case .rename:
        String(localized: "counter.accessibility.rename", locale: locale)
    }
    return CounterAccessibilityPolicy.actionLabel(
        format: format,
        counterName: projectCounterDisplayName(counter, locale: locale),
        currentValue: counter.value,
        locale: locale
    )
}
