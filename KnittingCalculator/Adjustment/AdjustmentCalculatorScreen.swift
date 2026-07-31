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
    let expandsRowDetails: Bool
#if DEBUG
    private let initialScrollTarget: String?
    private let initialScrollAnchor: UnitPoint
#endif
    @State private var mode: AdjustmentMode
    @State private var showsHelp = false

#if DEBUG
    init(
        initialMode: AdjustmentMode = .oneRow,
        expandsRowDetails: Bool = false,
        initialScrollTarget: String? = nil,
        initialScrollAnchor: UnitPoint = .top,
        onOneRowShareSnapshotChange: @escaping (OneRowShareSnapshot?) -> Void = { _ in },
        onRowIntervalShareSnapshotChange: @escaping (RowIntervalShareSnapshot?) -> Void = { _ in }
    ) {
        self.expandsRowDetails = expandsRowDetails
        self.initialScrollTarget = initialScrollTarget
        self.initialScrollAnchor = initialScrollAnchor
        _mode = State(initialValue: initialMode)
        self.onOneRowShareSnapshotChange = onOneRowShareSnapshotChange
        self.onRowIntervalShareSnapshotChange = onRowIntervalShareSnapshotChange
    }
#else
    init(
        initialMode: AdjustmentMode = .oneRow,
        expandsRowDetails: Bool = false,
        onOneRowShareSnapshotChange: @escaping (OneRowShareSnapshot?) -> Void = { _ in },
        onRowIntervalShareSnapshotChange: @escaping (RowIntervalShareSnapshot?) -> Void = { _ in }
    ) {
        self.expandsRowDetails = expandsRowDetails
        _mode = State(initialValue: initialMode)
        self.onOneRowShareSnapshotChange = onOneRowShareSnapshotChange
        self.onRowIntervalShareSnapshotChange = onRowIntervalShareSnapshotChange
    }
#endif

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
            .accessibilityValue(
                Text(
                    mode == .oneRow
                        ? "calculator.adjustment.mode.oneRow"
                        : "calculator.adjustment.mode.acrossRows"
                )
            )

            switch mode {
            case .oneRow:
                OneRowAdjustmentView(
                    preferences: preferences,
                    onShareSnapshotChange: onOneRowShareSnapshotChange
                )
            case .acrossRows:
#if DEBUG
                RowIntervalAdjustmentView(
                    preferences: preferences,
                    initiallyExpandsDetails: expandsRowDetails,
                    initialScrollTarget: initialScrollTarget,
                    initialScrollAnchor: initialScrollAnchor,
                    onShareSnapshotChange: onRowIntervalShareSnapshotChange
                )
#else
                RowIntervalAdjustmentView(
                    preferences: preferences,
                    initiallyExpandsDetails: expandsRowDetails,
                    onShareSnapshotChange: onRowIntervalShareSnapshotChange
                )
#endif
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
