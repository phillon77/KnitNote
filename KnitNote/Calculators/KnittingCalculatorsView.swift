import SwiftUI

struct KnittingCalculatorsView: View {
    var body: some View {
        ZStack {
            WatercolorBackground()

            ScrollView {
                VStack(spacing: 18) {
                    calculatorLink(
                        title: "calculator.gauge.title",
                        systemImage: "ruler"
                    ) {
                        GaugeCalculatorView()
                    }

                    calculatorLink(
                        title: "calculator.adjustment.title",
                        systemImage: "arrow.up.arrow.down"
                    ) {
                        EvenStitchAdjustmentCalculatorView()
                    }
                }
                .frame(maxWidth: 620)
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("calculator.tools.title")
    }

    private func calculatorLink<Destination: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            WatercolorCard {
                HStack(spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(WatercolorTheme.actionBerry)
                        .frame(width: 32)
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(WatercolorTheme.ink)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WatercolorTheme.actionBerry)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
    }
}
