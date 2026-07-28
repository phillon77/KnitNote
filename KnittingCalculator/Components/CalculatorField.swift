import SwiftUI

struct CalculatorField: View {
    enum InputKind {
        case decimal
        case integer
    }

    let title: LocalizedStringKey
    @Binding var text: String
    let kind: InputKind
    let validationKey: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))

            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(kind == .decimal ? .decimalPad : .numberPad)
                .frame(minHeight: 44)
                .accessibilityLabel(Text(title))

            if let validationKey {
                Text(validationKey)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
