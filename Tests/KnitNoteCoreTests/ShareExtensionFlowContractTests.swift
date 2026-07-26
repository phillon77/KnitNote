import Foundation
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite(.serialized) struct ShareExtensionFlowContractTests {
    @Test func providerSessionForwardsTemporaryURLSuggestedNameAndSelectedType() throws {
        let provider = FakeShareFileProvider(
            suggestedName: "Friendly Chart",
            registeredTypeIdentifiers: [
                UTType.fileURL.identifier,
                UTType.pdf.identifier,
            ]
        )
        let source = URL(fileURLWithPath: "/tmp/random-provider-file")
        let received = LockedLoadedFiles()
        let published = LockedShareResults()
        let session = PatternShareImportProviderSession(
            provider: provider,
            typeIdentifier: UTType.pdf.identifier,
            process: { file, cancellationToken in
                received.append(file)
                try cancellationToken.performCommit {}
            },
            publish: { published.append($0) }
        )

        session.start()
        provider.complete(with: source)

        #expect(received.values == [
            PatternShareImportLoadedFile(
                source: source,
                suggestedName: "Friendly Chart",
                typeIdentifier: UTType.pdf.identifier
            ),
        ])
        #expect(published.values == [.success])
        #expect(provider.loadRequests == [UTType.pdf.identifier])
    }

    @Test func cancelBeforeProviderCallbackCancelsProgressAndRejectsLateCallback() {
        let provider = FakeShareFileProvider(
            suggestedName: "Late.pdf",
            registeredTypeIdentifiers: [UTType.pdf.identifier]
        )
        let processed = FlowLockedCounter()
        let published = LockedShareResults()
        let session = PatternShareImportProviderSession(
            provider: provider,
            typeIdentifier: UTType.pdf.identifier,
            process: { _, _ in processed.increment() },
            publish: { published.append($0) }
        )

        session.start()
        #expect(session.cancel() == .cancelRequest)
        provider.complete(with: URL(fileURLWithPath: "/tmp/late"))

        #expect(provider.progress.isCancelled)
        #expect(processed.value == 0)
        #expect(published.values.isEmpty)
        #expect(session.cancel() == .none)
    }

    @Test func repeatedProviderCallbacksCanProcessAndPublishOnlyOnce() {
        let provider = FakeShareFileProvider(
            suggestedName: "Repeated.pdf",
            registeredTypeIdentifiers: [UTType.pdf.identifier]
        )
        let processed = FlowLockedCounter()
        let published = LockedShareResults()
        let session = PatternShareImportProviderSession(
            provider: provider,
            typeIdentifier: UTType.pdf.identifier,
            process: { _, token in
                processed.increment()
                try token.performCommit {}
            },
            publish: { published.append($0) }
        )

        session.start()
        let source = URL(fileURLWithPath: "/tmp/repeated")
        provider.complete(with: source)
        provider.complete(with: source)

        #expect(processed.value == 1)
        #expect(published.values == [.success])
    }

    @Test func cancelDuringProcessingSuppressesLatePublication() {
        let provider = FakeShareFileProvider(
            suggestedName: "Processing.pdf",
            registeredTypeIdentifiers: [UTType.pdf.identifier]
        )
        let processingStarted = DispatchSemaphore(value: 0)
        let allowProcessingToReturn = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)
        let published = LockedShareResults()
        let session = PatternShareImportProviderSession(
            provider: provider,
            typeIdentifier: UTType.pdf.identifier,
            process: { _, token in
                processingStarted.signal()
                _ = allowProcessingToReturn.wait(timeout: .now() + 10)
                try token.checkCancellation()
            },
            publish: { published.append($0) }
        )
        session.start()

        DispatchQueue.global().async {
            provider.complete(with: URL(fileURLWithPath: "/tmp/processing"))
            callbackFinished.signal()
        }
        #expect(processingStarted.wait(timeout: .now() + 10) == .success)
        #expect(session.cancel() == .cancelRequest)
        allowProcessingToReturn.signal()

        #expect(callbackFinished.wait(timeout: .now() + 10) == .success)
        #expect(published.values.isEmpty)
        #expect(session.cancel() == .none)
    }

    @Test func disappearanceAfterCommittedCallbackButBeforeUIReceiptCompletesOnce() throws {
        let provider = FakeShareFileProvider(
            suggestedName: "Committed.pdf",
            registeredTypeIdentifiers: [UTType.pdf.identifier]
        )
        let session = PatternShareImportProviderSession(
            provider: provider,
            typeIdentifier: UTType.pdf.identifier,
            process: { _, token in
                try token.performCommit {}
            },
            publish: { _ in }
        )
        session.start()

        provider.complete(with: URL(fileURLWithPath: "/tmp/committed"))

        #expect(session.cancel() == .completeRequest)
        #expect(session.cancel() == .none)
    }

    @Test func disappearanceAfterFailedCallbackButBeforeUIReceiptCancelsOnce() {
        let provider = FakeShareFileProvider(
            suggestedName: "Unavailable.pdf",
            registeredTypeIdentifiers: [UTType.pdf.identifier]
        )
        let session = PatternShareImportProviderSession(
            provider: provider,
            typeIdentifier: UTType.pdf.identifier,
            process: { _, _ in },
            publish: { _ in }
        )
        session.start()

        provider.complete(
            with: nil,
            error: CocoaError(.fileReadUnknown)
        )

        #expect(session.cancel() == .cancelRequest)
        #expect(session.cancel() == .none)
    }
}

private final class FakeShareFileProvider: PatternShareImportFileProvider, @unchecked Sendable {
    let suggestedName: String?
    let registeredTypeIdentifiers: [String]
    let progress = Progress(totalUnitCount: 1)
    private let lock = NSLock()
    private var completions: [@Sendable (URL?, (any Error)?) -> Void] = []
    private var loadRequestsStorage: [String] = []

    var loadRequests: [String] {
        lock.withLock { loadRequestsStorage }
    }

    init(
        suggestedName: String?,
        registeredTypeIdentifiers: [String]
    ) {
        self.suggestedName = suggestedName
        self.registeredTypeIdentifiers = registeredTypeIdentifiers
    }

    func loadFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completion: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> Progress {
        lock.withLock {
            loadRequestsStorage.append(typeIdentifier)
            completions.append(completion)
        }
        return progress
    }

    func complete(
        with url: URL?,
        error: (any Error)? = nil
    ) {
        let callbacks = lock.withLock { completions }
        for callback in callbacks {
            callback(url, error)
        }
    }
}

private final class LockedLoadedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PatternShareImportLoadedFile] = []

    var values: [PatternShareImportLoadedFile] {
        lock.withLock { storage }
    }

    func append(_ value: PatternShareImportLoadedFile) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class LockedShareResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PatternShareImportProviderResult] = []

    var values: [PatternShareImportProviderResult] {
        lock.withLock { storage }
    }

    func append(_ value: PatternShareImportProviderResult) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class FlowLockedCounter: @unchecked Sendable {
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
