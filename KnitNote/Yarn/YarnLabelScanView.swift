import SwiftUI

struct YarnLabelScanView: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: (YarnLabelScanOutput) -> Void
    @State private var images: [Data] = []
    @State private var reviewState: YarnLabelCandidateReviewState?
    @State private var isLoadingImages = false
    @State private var isScanning = false
    @State private var scanFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let reviewState {
                    YarnLabelCandidateReviewView(
                        state: Binding(
                            get: { reviewState },
                            set: { self.reviewState = $0 }
                        )
                    )
                } else {
                    ScrollView {
                        YarnLabelImagePicker(images: $images, isLoading: $isLoadingImages)
                            .padding(20)
                    }
                    .background(WatercolorBackground())
                }
            }
            .navigationTitle(reviewState == nil ? "yarn.scan.title" : "yarn.scan.review.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let reviewState {
                        Button("common.done") {
                            onComplete(.init(seed: reviewState.draftSeed, labelPhotos: images))
                        }
                    } else {
                        Button("yarn.scan.recognize") { scan() }
                            .disabled(images.isEmpty || isLoadingImages || isScanning)
                    }
                }
            }
            .overlay {
                if isScanning {
                    ProgressView("yarn.scan.recognizing")
                        .padding(18)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .alert("yarn.scan.failed", isPresented: $scanFailed) {
                Button("common.retry") { scan() }
                Button("common.cancel", role: .cancel) {}
            }
        }
        .frame(minWidth: 360, minHeight: 520)
        .tint(WatercolorTheme.actionBerry)
    }

    private func scan() {
        let scanImages = images
        isScanning = true
        Task {
            do {
                let result = try await YarnLabelScanSession(
                    recognizer: VisionYarnLabelRecognitionService()
                ).scan(scanImages)
                reviewState = YarnLabelCandidateReviewState(scanResult: result)
                isScanning = false
            } catch {
                isScanning = false
                scanFailed = true
            }
        }
    }
}
