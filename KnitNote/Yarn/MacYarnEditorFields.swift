import SwiftUI

#if os(macOS)
struct MacYarnEditorFieldFramePreferenceKey: PreferenceKey {
    static let coordinateSpaceName = "macYarnEditorLayoutHost"
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct MacYarnEditorFields: View {
    @Environment(\.locale) private var locale
    @Binding var draft: YarnEditorDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WatercolorCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("yarn.section.basic")
                    textField("yarn.name", text: $draft.name, identifier: "macYarnEditor.name")
                    textField("yarn.brand", text: $draft.brand, identifier: "macYarnEditor.brand")
                    textField("yarn.series", text: $draft.series, identifier: "macYarnEditor.series")
                    textField("yarn.color", text: $draft.color, identifier: "macYarnEditor.color")
                    textField("yarn.colorCode", text: $draft.colorCode, identifier: "macYarnEditor.colorCode")
                }
            }

            WatercolorCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("yarn.label.details")
                    textField("yarn.dyeLot", text: $draft.dyeLot, identifier: "macYarnEditor.dyeLot")
                    decimalField(
                        "yarn.ballWeightGrams",
                        text: $draft.ballWeightGrams.text,
                        identifier: "macYarnEditor.ballWeightGrams"
                    )
                    validationMessage(for: draft.ballWeightGrams)
                    decimalField(
                        "yarn.lengthMeters",
                        text: $draft.lengthMeters.text,
                        identifier: "macYarnEditor.lengthMeters"
                    )
                    validationMessage(for: draft.lengthMeters)
                    TextField("yarn.fiberContent", text: $draft.fiberContent, axis: .vertical)
                        .lineLimit(2...5)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("macYarnEditor.fiberContent")
                        .macYarnEditorLayoutFrame("macYarnEditor.fiberContent")
                    metricRangeFields(
                        "yarn.recommendedNeedleMM",
                        lower: $draft.needleLowerMM.text,
                        upper: $draft.needleUpperMM.text,
                        lowerIdentifier: "macYarnEditor.needleLower",
                        upperIdentifier: "macYarnEditor.needleUpper"
                    )
                    metricRangeFields(
                        "yarn.recommendedHookMM",
                        lower: $draft.hookLowerMM.text,
                        upper: $draft.hookUpperMM.text,
                        lowerIdentifier: "macYarnEditor.hookLower",
                        upperIdentifier: "macYarnEditor.hookUpper"
                    )
                }
            }

            WatercolorCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("yarn.section.inventory")
                    decimalField(
                        "yarn.remainingBalls",
                        text: $draft.remainingBalls.text,
                        identifier: "macYarnEditor.remainingBalls"
                    )
                    validationMessage(for: draft.remainingBalls)
                    decimalField(
                        "yarn.remainingGrams",
                        text: $draft.remainingGrams.text,
                        identifier: "macYarnEditor.remainingGrams"
                    )
                    validationMessage(for: draft.remainingGrams)
                }
            }

            WatercolorCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("yarn.section.storage")
                    textField(
                        "yarn.storageLocation",
                        text: $draft.storageLocation,
                        identifier: "macYarnEditor.storageLocation"
                    )
                    TextField("yarn.notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("macYarnEditor.notes")
                        .macYarnEditorLayoutFrame("macYarnEditor.notes")
                }
            }

            WatercolorCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("yarn.linkedProjects")
                    NavigationLink {
                        ChooseYarnProjectsView(selectedProjectIDs: $draft.linkedProjectIDs)
                    } label: {
                        LabeledContent("yarn.linkedProjects") {
                            Text(draft.linkedProjectIDs.count, format: .number)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.headline)
    }

    private func textField(
        _ titleKey: LocalizedStringKey,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        TextField(titleKey, text: text)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(identifier)
            .macYarnEditorLayoutFrame(identifier)
    }

    private func decimalField(
        _ titleKey: LocalizedStringKey,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        TextField(titleKey, text: text)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(identifier)
            .macYarnEditorLayoutFrame(identifier)
    }

    @ViewBuilder
    private func validationMessage(for value: YarnInventoryEditValue) -> some View {
        switch value.input(locale: locale) {
        case .invalid:
            Text("yarn.error.invalidNumber")
                .font(.caption)
                .foregroundStyle(.red)
        case .negative:
            Text("yarn.error.negativeInventory")
                .font(.caption)
                .foregroundStyle(.red)
        case .empty, .value:
            EmptyView()
        }
    }

    private func metricRangeFields(
        _ titleKey: LocalizedStringKey,
        lower: Binding<String>,
        upper: Binding<String>,
        lowerIdentifier: String,
        upperIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleKey)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("yarn.range.lower", text: lower)
                    .accessibilityIdentifier(lowerIdentifier)
                    .macYarnEditorLayoutFrame(lowerIdentifier)
                Text("–")
                    .foregroundStyle(.secondary)
                TextField("yarn.range.upper", text: upper)
                    .accessibilityIdentifier(upperIdentifier)
                    .macYarnEditorLayoutFrame(upperIdentifier)
                Text("mm")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    func macYarnEditorLayoutFrame(_ identifier: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MacYarnEditorFieldFramePreferenceKey.self,
                    value: [
                        identifier: proxy.frame(
                            in: .named(MacYarnEditorFieldFramePreferenceKey.coordinateSpaceName)
                        ),
                    ]
                )
            }
        }
    }
}
#endif
