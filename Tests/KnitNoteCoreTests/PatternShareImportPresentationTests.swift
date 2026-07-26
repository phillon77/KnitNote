import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternShareImportPresentationTests {
    @Test(arguments: [
        "com.adobe.pdf",
        "public.png",
        "public.jpeg",
        "public.heic",
    ])
    func selectorAcceptsExactlyOneSupportedFileProvider(
        typeIdentifier: String
    ) throws {
        #expect(try PatternShareImportAttachmentSelector.indexOfSingleSupportedFile(
            in: [["public.file-url", typeIdentifier]]
        ) == 0)
    }

    @Test(arguments: [
        ([[String]](), PatternShareImportSelectionError.noAttachment),
        ([["public.url"]], .unsupported),
        ([["com.adobe.pdf"], ["com.adobe.pdf"]], .multipleAttachments),
        ([["com.adobe.pdf"], ["public.url"]], .multipleAttachments),
    ])
    func selectorRejectsMissingUnsupportedAndMultipleProviders(
        registeredTypes: [[String]],
        expected: PatternShareImportSelectionError
    ) {
        #expect(throws: expected) {
            _ = try PatternShareImportAttachmentSelector.indexOfSingleSupportedFile(
                in: registeredTypes
            )
        }
    }

    @Test(arguments: [
        ("com.adobe.pdf", "com.adobe.pdf"),
        ("public.png", "public.png"),
        ("public.jpeg", "public.jpeg"),
        ("public.heic", "public.heic"),
    ])
    func providerSelectionReturnsTheSupportedRepresentation(
        typeIdentifier: String,
        expected: String
    ) throws {
        let selection = try PatternShareImportProviderSelection.select(
            from: [[["public.file-url", typeIdentifier]]]
        )

        #expect(selection.itemIndex == 0)
        #expect(selection.attachmentIndex == 0)
        #expect(selection.typeIdentifier == expected)
    }

    @Test func providerSelectionRejectsMultipleExtensionItemsEvenWithOneAttachment() {
        #expect(throws: PatternShareImportSelectionError.multipleAttachments) {
            _ = try PatternShareImportProviderSelection.select(
                from: [[["com.adobe.pdf"]], []]
            )
        }
    }

    @Test func completionGateAllowsOnlyOneCallbackToClaimAndPublish() {
        let gate = PatternShareImportCompletionGate()
        let acceptedClaims = LockedCounter()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if gate.beginProcessing() {
                acceptedClaims.increment()
            }
        }

        #expect(acceptedClaims.value == 1)
        #expect(gate.finish())
        #expect(!gate.finish())
        #expect(!gate.beginProcessing())
    }

    @Test func cancellationRejectsLateCallbacksAndPublication() {
        let waitingGate = PatternShareImportCompletionGate()
        #expect(waitingGate.cancel())
        #expect(!waitingGate.cancel())
        #expect(!waitingGate.beginProcessing())
        #expect(!waitingGate.finish())

        let processingGate = PatternShareImportCompletionGate()
        #expect(processingGate.beginProcessing())
        #expect(processingGate.cancel())
        #expect(!processingGate.finish())
    }

    @Test func timeoutWinsOnlyWhileWaitingForTheProvider() {
        let waitingGate = PatternShareImportCompletionGate()
        #expect(waitingGate.timeout())
        #expect(!waitingGate.beginProcessing())

        let processingGate = PatternShareImportCompletionGate()
        #expect(processingGate.beginProcessing())
        #expect(!processingGate.timeout())
        #expect(processingGate.finish())
    }

    @Test func everyShareFailureMapsToAStableLocalizedMessage() {
        let cases: [(any Error, PatternShareImportErrorMessage)] = [
            (PatternShareImportSelectionError.noAttachment, .unsupported),
            (PatternShareImportSelectionError.unsupported, .unsupported),
            (PatternShareImportSelectionError.multipleAttachments, .multipleAttachments),
            (PatternShareImportFailure.accessDenied, .accessDenied),
            (PatternShareImportFailure.loadFailed, .loadFailed),
            (PatternShareImportFailure.timedOut, .timedOut),
            (PatternShareImportFailure.cancelled, .cancelled),
            (PatternFileError.empty, .emptyFile),
            (PatternFileError.tooLarge, .fileTooLarge),
            (PatternFileError.unsupported, .invalidFile),
            (PatternFileError.invalidContent, .invalidFile),
            (PatternFileError.unsafeStoredFilename, .storageUnavailable),
            (PatternInboxError.appGroupUnavailable, .storageUnavailable),
            (PatternInboxError.itemNotFound, .storageUnavailable),
            (PatternInboxError.invalidItem, .storageUnavailable),
            (PatternInboxError.invalidSelection, .storageUnavailable),
            (CocoaError(.fileReadNoPermission), .accessDenied),
            (CocoaError(.fileReadUnknown), .unexpected),
        ]

        for (error, expected) in cases {
            #expect(PatternShareImportErrorMapper.message(for: error) == expected)
        }
    }

    @Test func providerLoadErrorsDistinguishAccessFromLoadingFailures() {
        #expect(
            PatternShareImportErrorMapper.messageForProviderLoad(
                CocoaError(.fileReadNoPermission)
            ) == .accessDenied
        )
        #expect(
            PatternShareImportErrorMapper.messageForProviderLoad(
                CocoaError(.fileReadUnknown)
            ) == .loadFailed
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}
