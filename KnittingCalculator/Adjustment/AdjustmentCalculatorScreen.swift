import SwiftUI

enum AdjustmentMode: String, CaseIterable, Identifiable {
    case oneRow
    case acrossRows

    var id: Self { self }
}

struct AdjustmentCalculatorScreen: View {
    @EnvironmentObject private var preferences: CalculatorPreferencesStore
    let onOneRowShareSnapshotChange: (OneRowShareSnapshot?) -> Void
    let onRowIntervalShareSnapshotChange: (RowIntervalShareSnapshot?) -> Void
    @State private var mode = AdjustmentMode.oneRow
    @State private var showsHelp = false

    init(
        onOneRowShareSnapshotChange: @escaping (OneRowShareSnapshot?) -> Void = { _ in },
        onRowIntervalShareSnapshotChange: @escaping (RowIntervalShareSnapshot?) -> Void = { _ in }
    ) {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsHelp = true
                } label: {
                    Label("calculator.help.title", systemImage: "questionmark.circle")
                }
                .accessibilityLabel(Text("calculator.help.title"))
            }
        }
        .sheet(isPresented: $showsHelp) {
            CalculatorHelpSheet(tool: .adjustment)
        }
    }
}
