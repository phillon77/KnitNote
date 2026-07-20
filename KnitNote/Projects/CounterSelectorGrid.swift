import SwiftUI

private struct CounterActionTouchTargetModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(
                minWidth: CounterActionControlPolicy.minimumTouchTarget,
                minHeight: CounterActionControlPolicy.minimumTouchTarget
            )
            .contentShape(Rectangle())
    }
}

extension View {
    func counterActionTouchTarget() -> some View {
        modifier(CounterActionTouchTargetModifier())
    }
}

func projectCounterColor(_ ordinal: Int) -> Color {
    let colors: [Color] = [
        WatercolorTheme.actionBerry,
        .orange,
        .blue,
        .green,
        .purple,
        .teal,
    ]
    return colors[max(0, ordinal - 1) % colors.count]
}

struct CounterSelectorGrid: View {
    @Environment(\.locale) private var locale
    let counters: [ProjectCounter]
    let selectedCounterID: UUID
    let isEnabled: Bool
    let onIncrement: (UUID) -> Void
    let onManage: (UUID) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(counters) { counter in
                counterCell(counter)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("counter.summary"))
    }

    private func counterCell(_ counter: ProjectCounter) -> some View {
        let name = projectCounterDisplayName(counter, locale: locale)
        let isSelected = counter.id == selectedCounterID
        return VStack(spacing: 4) {
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity)
            Text(counter.value, format: .number)
                .font(.title2.bold().monospacedDigit())
        }
        .foregroundStyle(isSelected ? .white : WatercolorTheme.ink)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(
            isSelected ? projectCounterColor(counter.defaultOrdinal) : WatercolorTheme.softWhite.opacity(0.88),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(projectCounterColor(counter.defaultOrdinal).opacity(isSelected ? 0 : 0.45), lineWidth: 1)
        }
        .counterActionTouchTarget()
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .opacity(isEnabled ? 1 : 0.62)
        .onTapGesture {
            guard isEnabled else { return }
            onIncrement(counter.id)
        }
        .onLongPressGesture(minimumDuration: 0.55) {
            guard isEnabled else { return }
            onManage(counter.id)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(counter.value, format: .number))
        .accessibilityHint(Text("counter.accessibility.tapHoldHint"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("counter.increment")) {
            guard isEnabled else { return }
            onIncrement(counter.id)
        }
        .accessibilityAction(named: Text("counter.manage")) {
            guard isEnabled else { return }
            onManage(counter.id)
        }
    }
}
