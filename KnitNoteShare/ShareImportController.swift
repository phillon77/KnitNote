import Foundation

enum ShareImportViewState: Equatable {
    case loading
    case success
    case failure(PatternShareImportErrorMessage)

    var messageKey: String {
        switch self {
        case .loading:
            return "share.loading"
        case .success:
            return "share.success"
        case let .failure(message):
            return message.rawValue
        }
    }
}

private enum ShareImportWorkerResult: Sendable {
    case success
    case failure(PatternShareImportErrorMessage)
}

@MainActor
final class ShareImportController: ObservableObject {
    @Published private(set) var state = ShareImportViewState.loading

    private static let workerQueue = DispatchQueue(
        label: "com.phillon.KnitNote.share-import",
        qos: .userInitiated
    )
    private let extensionContext: NSExtensionContext?
    private var operationGate: PatternShareImportCompletionGate?
    private var providerProgress: Progress?
    private var timeoutTask: Task<Void, Never>?
    private var successCompletionTask: Task<Void, Never>?
    private var contextFinished = false
    private var started = false

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext
    }

    func start() {
        guard !started else { return }
        started = true

        do {
            let items = extensionContext?.inputItems.compactMap {
                $0 as? NSExtensionItem
            } ?? []
            let typeIdentifiers = items.map { item in
                (item.attachments ?? []).map(\.registeredTypeIdentifiers)
            }
            let selection = try PatternShareImportProviderSelection.select(
                from: typeIdentifiers
            )
            let provider = try provider(
                for: selection,
                in: items
            )
            load(
                provider: provider,
                typeIdentifier: selection.typeIdentifier
            )
        } catch {
            state = .failure(
                PatternShareImportErrorMapper.message(for: error)
            )
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        successCompletionTask?.cancel()
        providerProgress?.cancel()
        _ = operationGate?.cancel()
        cancelRequest(with: PatternShareImportFailure.cancelled)
    }

    func close() {
        switch state {
        case .success:
            completeRequest()
        case .loading, .failure:
            cancelRequest(with: PatternShareImportFailure.cancelled)
        }
    }

    func cancelIfNeeded() {
        guard !contextFinished else { return }
        cancel()
    }

    private func provider(
        for selection: PatternShareImportProviderSelection,
        in items: [NSExtensionItem]
    ) throws -> NSItemProvider {
        guard items.indices.contains(selection.itemIndex),
              let attachments = items[selection.itemIndex].attachments,
              attachments.indices.contains(selection.attachmentIndex) else {
            throw PatternShareImportSelectionError.noAttachment
        }
        return attachments[selection.attachmentIndex]
    }

    private func load(
        provider: NSItemProvider,
        typeIdentifier: String
    ) {
        let gate = PatternShareImportCompletionGate()
        operationGate = gate
        let workerQueue = Self.workerQueue
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled,
                  gate.timeout() else { return }
            self?.providerProgress?.cancel()
            self?.providerProgress = nil
            self?.state = .failure(.timedOut)
        }

        providerProgress = provider.loadFileRepresentation(
            forTypeIdentifier: typeIdentifier
        ) { [weak self] url, providerError in
            guard gate.beginProcessing() else { return }
            let result: ShareImportWorkerResult
            if let providerError {
                result = .failure(
                    PatternShareImportErrorMapper.messageForProviderLoad(
                        providerError
                    )
                )
            } else if let url {
                result = workerQueue.sync {
                    do {
                        let locations = try PatternStorageLocations.live()
                        _ = try PatternShareInboxEnqueuer(
                            inboxRoot: locations.inboxRoot
                        ).enqueue(
                            source: url,
                            now: .now
                        )
                        return .success
                    } catch {
                        return .failure(
                            PatternShareImportErrorMapper.message(
                                for: error
                            )
                        )
                    }
                }
            } else {
                result = .failure(.loadFailed)
            }
            guard gate.finish() else { return }
            Task { @MainActor [weak self] in
                self?.receive(result)
            }
        }
    }

    private func receive(_ result: ShareImportWorkerResult) {
        timeoutTask?.cancel()
        timeoutTask = nil
        providerProgress = nil
        switch result {
        case .success:
            state = .success
            successCompletionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self?.completeRequest()
            }
        case let .failure(message):
            state = .failure(message)
        }
    }

    private func completeRequest() {
        guard !contextFinished else { return }
        contextFinished = true
        timeoutTask?.cancel()
        successCompletionTask?.cancel()
        extensionContext?.completeRequest(
            returningItems: nil,
            completionHandler: nil
        )
    }

    private func cancelRequest(with error: any Error) {
        guard !contextFinished else { return }
        contextFinished = true
        timeoutTask?.cancel()
        successCompletionTask?.cancel()
        extensionContext?.cancelRequest(withError: error)
    }
}
