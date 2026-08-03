import SwiftUI

struct YarnSheetLocaleBridge<Content: View>: View {
    let locale: Locale
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.locale, locale)
    }
}

struct YarnLabelScanOutput {
    let seed: YarnLabelDraftSeed
    let labelPhotos: [Data]
}

struct YarnLabelScanLauncher<Label: View>: View {
    @Environment(\.locale) private var locale
    let onComplete: (YarnLabelScanOutput) -> Void
    @ViewBuilder let label: () -> Label
    @State private var showingScan = false
    @State private var pendingOutput: YarnLabelScanOutput?

    var body: some View {
        Button { showingScan = true } label: { label() }
            .accessibilityHint(Text("yarn.scan.action.hint"))
            .sheet(isPresented: $showingScan, onDismiss: publishPendingOutput) {
                YarnSheetLocaleBridge(locale: locale) {
                    YarnLabelScanView { output in
                        pendingOutput = output
                        showingScan = false
                    }
                }
            }
    }

    private func publishPendingOutput() {
        guard let pendingOutput else { return }
        self.pendingOutput = nil
        onComplete(pendingOutput)
    }
}
