import SwiftUI

struct YarnLabelCandidateReviewView: View {
    @Binding var state: YarnLabelCandidateReviewState

    var body: some View {
        Form {
            Section("yarn.scan.review.message") {
                ForEach(YarnLabelField.allCases, id: \.self) { field in
                    let candidates = state.scanResult.candidates(for: field)
                    if !candidates.isEmpty {
                        candidatePicker(field: field, candidates: candidates)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WatercolorBackground())
    }

    private func candidatePicker(
        field: YarnLabelField,
        candidates: [YarnLabelCandidate]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(field.titleKey, selection: selection(for: field)) {
                Text("yarn.scan.leaveBlank").tag(-1)
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                    Text(candidate.text).tag(index)
                }
            }
            if requiresConfirmation(field: field, candidates: candidates) {
                Label("yarn.scan.needsConfirmation", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint(Text("yarn.scan.review.hint"))
    }

    private func requiresConfirmation(
        field: YarnLabelField,
        candidates: [YarnLabelCandidate]
    ) -> Bool {
        state.scanResult.fieldsRequiringConfirmation.contains(field) ||
            candidates.count > 1 ||
            state.selectedCandidate(for: field) == nil
    }

    private func selection(for field: YarnLabelField) -> Binding<Int> {
        Binding(
            get: {
                guard let selected = state.selectedCandidate(for: field) else { return -1 }
                return state.scanResult.candidates(for: field).firstIndex(of: selected) ?? -1
            },
            set: { index in
                guard index >= 0 else {
                    state.clearSelection(for: field)
                    return
                }
                let candidates = state.scanResult.candidates(for: field)
                guard candidates.indices.contains(index) else { return }
                _ = state.select(candidates[index], for: field)
            }
        )
    }
}

private extension YarnLabelField {
    var titleKey: LocalizedStringKey {
        switch self {
        case .brand: "yarn.brand"
        case .series: "yarn.series"
        case .color: "yarn.color"
        case .colorCode: "yarn.colorCode"
        case .dyeLot: "yarn.dyeLot"
        case .ballWeightGrams: "yarn.ballWeightGrams"
        case .lengthMeters: "yarn.lengthMeters"
        case .fiberContent: "yarn.fiberContent"
        case .recommendedNeedleMM: "yarn.recommendedNeedleMM"
        case .recommendedHookMM: "yarn.recommendedHookMM"
        }
    }
}
