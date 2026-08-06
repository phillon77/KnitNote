import Foundation

func projectCounterDisplayName(_ counter: ProjectCounter, locale: Locale) -> String {
    counter.customName ?? LocaleAwareText.format(
        "counter.defaultName",
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
        LocaleAwareText.string("counter.accessibility.collapse", locale: locale)
    case .decrement:
        LocaleAwareText.string("counter.accessibility.decrement", locale: locale)
    case .expand:
        LocaleAwareText.string("counter.accessibility.expand", locale: locale)
    case .increment:
        LocaleAwareText.string("counter.accessibility.increment", locale: locale)
    case .note:
        LocaleAwareText.string("counter.accessibility.note", locale: locale)
    case .rename:
        LocaleAwareText.string("counter.accessibility.rename", locale: locale)
    }
    return CounterAccessibilityPolicy.actionLabel(
        format: format,
        counterName: projectCounterDisplayName(counter, locale: locale),
        currentValue: counter.value,
        locale: locale
    )
}
