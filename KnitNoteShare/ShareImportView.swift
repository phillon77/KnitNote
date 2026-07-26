import SwiftUI

struct ShareImportView: View {
    @ObservedObject var controller: ShareImportController
    private let defaultErrorKey = "share.error.unexpected"

    var body: some View {
        VStack(spacing: 20) {
            Text("share.title")
                .font(.headline)

            status

            Button(actionTitle) {
                action()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(Text(actionTitle))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
            statusText("share.loading")
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            statusText("share.success")
        case let .failure(message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            statusText(
                message.rawValue.isEmpty
                    ? defaultErrorKey
                    : message.rawValue
            )
        }
    }

    private func statusText(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .multilineTextAlignment(.center)
            .accessibilityLabel(Text(LocalizedStringKey(key)))
    }

    private var actionTitle: LocalizedStringKey {
        controller.state == .loading
            ? "share.cancel"
            : "share.close"
    }

    private func action() {
        if controller.state == .loading {
            controller.cancel()
        } else {
            controller.close()
        }
    }
}
