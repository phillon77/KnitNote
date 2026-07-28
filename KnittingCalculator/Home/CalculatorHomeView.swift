import SwiftUI

struct CalculatorHomeView: View {
    var body: some View {
        ZStack {
            CalculatorWatercolorBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("app.home.title")
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                        .padding(.bottom, 8)

                    NavigationLink {
                        GaugeCalculatorScreen()
                    } label: {
                        CalculatorToolCard(
                            title: "calculator.gauge.title",
                            description: "calculator.home.gauge.description",
                            symbol: "ruler"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("calculator.home.gauge.description"))

                    NavigationLink {
                        AdjustmentCalculatorScreen()
                    } label: {
                        CalculatorToolCard(
                            title: "calculator.adjustment.title",
                            description: "calculator.home.adjustment.description",
                            symbol: "arrow.left.and.right"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("calculator.home.adjustment.description"))

                    KnitNotePromotionCard()
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Knitting Calculator")
    }
}

private struct CalculatorToolCard: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let symbol: String

    var body: some View {
        CalculatorCard {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(CalculatorTheme.berry)
                    .frame(width: 44, height: 44)
                    .background(CalculatorTheme.blush.opacity(0.75), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
        }
        .contentShape(RoundedRectangle(cornerRadius: 24))
    }
}
