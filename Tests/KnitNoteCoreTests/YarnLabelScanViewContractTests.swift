import Foundation
import Testing

@Suite struct YarnLabelScanViewContractTests {
    @Test func libraryOffersScanAndManualCreation() throws {
        let library = try source("YarnLibraryView.swift")
        let entry = try source("CreateYarnEntryView.swift")

        #expect(library.contains("CreateYarnEntryView()"))
        #expect(entry.contains("YarnLabelScanLauncher"))
        #expect(entry.contains("yarn.addManually"))
    }

    @Test func pickerCapsSelectionAndKeepsPlatformSpecificSources() throws {
        let picker = try source("YarnLabelImagePicker.swift")

        #expect(picker.contains("maxSelectionCount: 2"))
        #expect(picker.contains("images.count < 2"))
        #expect(picker.contains("CameraCaptureView"))
        #expect(picker.contains("MacYarnLabelFileImporter"))
        #expect(picker.contains("allowsMultipleSelection: true"))
    }

    @Test func scanRequiresReviewBeforePublishingDraft() throws {
        let scan = try source("YarnLabelScanView.swift")
        let review = try source("YarnLabelCandidateReviewView.swift")

        #expect(scan.contains("YarnLabelCandidateReviewState"))
        #expect(scan.contains("reviewState.draftSeed"))
        #expect(review.contains("yarn.scan.leaveBlank"))
        #expect(review.contains("yarn.scan.needsConfirmation"))
    }

    @Test func scanCompletionWaitsForSheetDismissalAndDeniedCameraCanOpenPhotos() throws {
        let launcher = try source("YarnLabelScanLauncher.swift")
        let picker = try source("YarnLabelImagePicker.swift")

        #expect(launcher.contains("onDismiss:"))
        #expect(launcher.contains("pendingOutput"))
        #expect(picker.contains("showingPhotoLibrary = true"))
        #expect(picker.contains(".photosPicker("))
    }

    private func source(_ name: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appending(path: "KnitNote/Yarn/\(name)"),
            encoding: .utf8
        )
    }
}
