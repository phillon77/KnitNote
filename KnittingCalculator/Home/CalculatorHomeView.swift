import SwiftUI
import ShortRowKit

struct CalculatorHomeView: View {
    @Environment(\.locale) private var locale
    @State private var isHomeVisible = false
#if DEBUG
    private let initialScrollTarget: String?

    init(initialScrollTarget: String? = nil) {
        self.initialScrollTarget = initialScrollTarget
    }
#else
    init() {}
#endif

    var body: some View {
        ZStack {
            CalculatorWatercolorBackground()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear
                            .frame(height: 0)
                            .id("top")

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

                        NavigationLink {
                            StitchDictionaryView()
                        } label: {
                            CalculatorToolCard(
                                title: "stitchDictionary.title",
                                description: "stitchDictionary.search.prompt",
                                symbol: "book.closed"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("calculator.stitchDictionary")

                        NavigationLink {
                            ShortRowCalculatorView()
                        } label: {
                            CalculatorToolCard(
                                title: LocalizedStringKey(ShortRowTool.title(locale: locale)),
                                description: LocalizedStringKey(ShortRowTool.summary(locale: locale)),
                                symbol: "stairs"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("calculator.shortRows")

                        KnitNotePromotionCard()
                            .id("promotion")
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
#if DEBUG
                .task(id: initialScrollTarget) {
                    guard let initialScrollTarget else { return }
                    await Task.yield()
                    proxy.scrollTo(initialScrollTarget, anchor: .top)
                }
#endif
            }
        }
        .navigationTitle("app.title")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CalculatorBannerPlacement(isHomeVisible: isHomeVisible)
        }
        .onAppear { isHomeVisible = true }
        .onDisappear { isHomeVisible = false }
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
