import SwiftUI

enum AdjustmentMode: String, CaseIterable, Identifiable {
    case oneRow
    case acrossRows

    var id: Self { self }
}

struct AdjustmentCalculatorScreen: View {
    @ObservedObject var preferences: CalculatorPreferencesStore
    let onOneRowShareSnapshotChange: (OneRowShareSnapshot?) -> Void
    let onRowIntervalShareSnapshotChange: (RowIntervalShareSnapshot?) -> Void
    @State private var mode = AdjustmentMode.oneRow

    init(
        preferences: CalculatorPreferencesStore,
        onOneRowShareSnapshotChange: @escaping (OneRowShareSnapshot?) -> Void = { _ in },
        onRowIntervalShareSnapshotChange: @escaping (RowIntervalShareSnapshot?) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.onOneRowShareSnapshotChange = onOneRowShareSnapshotChange
        self.onRowIntervalShareSnapshotChange = onRowIntervalShareSnapshotChange
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("calculator.adjustment.mode", selection: $mode) {
                Text("calculator.adjustment.mode.oneRow")
                    .tag(AdjustmentMode.oneRow)
                Text("calculator.adjustment.mode.acrossRows")
                    .tag(AdjustmentMode.acrossRows)
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
            .accessibilityLabel(Text("calculator.adjustment.mode"))

            switch mode {
            case .oneRow:
                OneRowAdjustmentView(
                    preferences: preferences,
                    onShareSnapshotChange: onOneRowShareSnapshotChange
                )
            case .acrossRows:
                RowIntervalAdjustmentView(
                    preferences: preferences,
                    onShareSnapshotChange: onRowIntervalShareSnapshotChange
                )
            }
        }
        .navigationTitle("calculator.adjustment.title")
    }
}
