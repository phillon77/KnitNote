import SwiftUI

struct CalculatorHelpSheet: View {
    enum Tool {
        case gauge
        case adjustment
    }

    let tool: Tool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(purpose)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle("calculator.help.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("calculator.help.dismiss") {
                        dismiss()
                    }
                    .accessibilityLabel(Text("calculator.help.dismiss"))
                }
            }
        }
    }

    private var purpose: LocalizedStringKey {
        switch tool {
        case .gauge:
            "calculator.help.gauge"
        case .adjustment:
            "calculator.help.adjustment"
        }
    }
}
