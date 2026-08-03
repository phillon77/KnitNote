import SwiftUI

struct YarnLabelScanOutput {
    let seed: YarnLabelDraftSeed
    let labelPhotos: [Data]
}

struct YarnLabelScanLauncher<Label: View>: View {
    let onComplete: (YarnLabelScanOutput) -> Void
    @ViewBuilder let label: () -> Label
    @State private var showingScan = false
    @State private var pendingOutput: YarnLabelScanOutput?

    var body: some View {
        Button { showingScan = true } label: { label() }
            .accessibilityHint(Text("yarn.scan.action.hint"))
            .sheet(isPresented: $showingScan, onDismiss: publishPendingOutput) {
                YarnLabelScanView { output in
                    pendingOutput = output
                    showingScan = false
                }
            }
    }

    private func publishPendingOutput() {
        guard let pendingOutput else { return }
        self.pendingOutput = nil
        onComplete(pendingOutput)
    }
}
