import Foundation

enum ShareImportViewState: Equatable {
    case loading
    case success
    case entitlementBlocked
    case failure(PatternShareImportErrorMessage)

    var messageKey: String {
        switch self {
        case .loading:
            return "share.loading"
        case .success:
            return "share.success"
        case .entitlementBlocked:
            return "share.entitlement.blocked"
        case let .failure(message):
            return message.rawValue
        }
    }
}

private final class ShareItemProviderAdapter: PatternShareImportFileProvider, @unchecked Sendable {
    private let provider: NSItemProvider

    var suggestedName: String? {
        provider.suggestedName
    }

    var registeredTypeIdentifiers: [String] {
        provider.registeredTypeIdentifiers
    }

    init(provider: NSItemProvider) {
        self.provider = provider
    }

    func loadFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completion: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> Progress {
        provider.loadFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            completionHandler: completion
        )
    }
}

@MainActor
final class ShareImportController: ObservableObject {
    @Published private(set) var state = ShareImportViewState.loading

    private static let workerQueue = DispatchQueue(
        label: "com.phillon.KnitNote.share-import",
        qos: .userInitiated
    )
    private let extensionContext: NSExtensionContext?
    private let entitlementReader: EntitlementProjectionReader
    private let now: () -> Date
    private var providerSession: PatternShareImportProviderSession?
    private var timeoutTask: Task<Void, Never>?
    private var successCompletionTask: Task<Void, Never>?
    private var contextFinished = false
    private var started = false

    init(
        extensionContext: NSExtensionContext?,
        entitlementReader: EntitlementProjectionReader = .live(),
        now: @escaping () -> Date = Date.init
    ) {
        self.extensionContext = extensionContext
        self.entitlementReader = entitlementReader
        self.now = now
    }

    func start() {
        guard !started else { return }
        started = true

        guard entitlementReader.canAcceptImport(now: now()) else {
            state = .entitlementBlocked
            return
        }

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
        switch state {
        case .success:
            completeRequest()
        case .entitlementBlocked, .failure:
            cancelRequest(with: PatternShareImportFailure.cancelled)
        case .loading:
            switch providerSession?.cancel() ?? .cancelRequest {
            case .cancelRequest:
                successCompletionTask?.cancel()
                cancelRequest(with: PatternShareImportFailure.cancelled)
            case .completeRequest:
                state = .success
                completeRequest()
            case .none:
                break
            }
        }
    }

    func close() {
        switch state {
        case .success:
            completeRequest()
        case .loading, .entitlementBlocked, .failure:
            cancelRequest(with: PatternShareImportFailure.cancelled)
        }
    }

    func openKnitNote() {
        guard let url = URL(string: "knitnote://open"),
              let extensionContext else {
            close()
            return
        }
        extensionContext.open(url) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completeRequest()
            }
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
        let workerQueue = Self.workerQueue
        let session = PatternShareImportProviderSession(
            provider: ShareItemProviderAdapter(provider: provider),
            typeIdentifier: typeIdentifier,
            process: { file, cancellationToken in
                try workerQueue.sync {
                    let locations = try PatternStorageLocations.live()
                    _ = try PatternShareInboxEnqueuer(
                        inboxRoot: locations.inboxRoot
                    ).enqueue(
                        source: file.source,
                        suggestedName: file.suggestedName,
                        typeIdentifier: file.typeIdentifier,
                        now: .now,
                        cancellationToken: cancellationToken
                    )
                }
            },
            publish: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.receive(result)
                }
            }
        )
        providerSession = session
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled,
                  session.timeout() else { return }
            self?.state = .failure(.timedOut)
        }
        session.start()
    }

    private func receive(_ result: PatternShareImportProviderResult) {
        timeoutTask?.cancel()
        timeoutTask = nil
        providerSession = nil
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
