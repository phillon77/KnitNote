import SwiftUI

struct CalculatorResultActions: View {
    let text: String
    let onSuccessfulAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                #if os(iOS)
                UIPasteboard.general.string = text
                #endif
                onSuccessfulAction()
            } label: {
                Label("calculator.resultActions.copy", systemImage: "doc.on.doc")
            }
            .accessibilityLabel(Text("calculator.resultActions.copy.accessibility"))
            .frame(minWidth: 44, minHeight: 44)

            ShareLink(item: text) {
                Label("calculator.resultActions.share", systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel(Text("calculator.resultActions.share.accessibility"))
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}
