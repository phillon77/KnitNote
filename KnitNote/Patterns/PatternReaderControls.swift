import SwiftUI

struct PatternReaderControls: View {
    @Environment(\.locale) private var locale
    let counters: [ProjectCounter]
    let isEnabled: Bool
    let pageIndex: Int
    let pageCount: Int
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onIncrement: (UUID) -> Void
    let onManage: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            if pageCount > 0 {
                VStack {
                    Spacer()
                    pageControls
                }
            }
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    ForEach(counters) { counter in
                        counterButton(counter)
                    }
                }
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.trailing, 8)
            }
        }
        .padding(.bottom, 8)
    }

    private var pageControls: some View {
        HStack {
            Button(action: onPreviousPage) {
                Label("patterns.previousPage", systemImage: "chevron.left")
            }
            .disabled(pageIndex == 0)
            Spacer()
            Text(verbatim: "\(pageIndex + 1) / \(pageCount)")
                .font(.caption.monospacedDigit())
            Spacer()
            Button(action: onNextPage) {
                Label("patterns.nextPage", systemImage: "chevron.right")
            }
            .disabled(pageIndex >= pageCount - 1)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 14)
    }

    private func counterButton(_ counter: ProjectCounter) -> some View {
        let name = projectCounterDisplayName(counter, locale: locale)
        return Text(counter.value, format: .number)
            .font(.headline.bold().monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(projectCounterColor(counter.defaultOrdinal), in: Circle())
            .counterActionTouchTarget()
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Circle())
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
