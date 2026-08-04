import Combine
import Foundation

public struct YouTubePatternPresentationMetadata: Sendable {
    public let title: String?
    public let thumbnailData: Data?

    public init(title: String?, thumbnailData: Data?) {
        self.title = title
        self.thumbnailData = thumbnailData
    }
}

@MainActor
public protocol YouTubePatternMetadataFetching {
    func fetch(for url: URL) async throws -> YouTubePatternPresentationMetadata
}

public enum YouTubeMetadataFetchError: Error, Equatable, Sendable {
    case timedOut
}

/// Returns as soon as either operation completes or the timeout expires. The
/// operation is cancelled on timeout, but a misbehaving provider is never
/// allowed to hold this caller past the deadline.
@MainActor
public func withYouTubeMetadataTimeout<T: Sendable>(
    timeout: Duration = .seconds(10),
    _ operation: @escaping @MainActor @Sendable () async throws -> T
) async throws -> T {
    let race = YouTubeMetadataTimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await race.start(
                    continuation: continuation,
                    timeout: timeout,
                    operation: operation
                )
            }
        }
    } onCancel: {
        Task {
            await race.cancel()
        }
    }
}

@MainActor
public enum YouTubePatternAddFetchState: Equatable {
    case idle
    case loading
    case loaded(thumbnailData: Data?)
    case manualEntry(messageKey: String)
}

@MainActor
public final class YouTubePatternAddCoordinator: ObservableObject {
    @Published public var urlText = "" {
        didSet {
            guard oldValue != urlText else { return }
            cancelMetadataRequest()
            parsedLink = nil
            fetchState = .idle
        }
    }
    @Published public var title = ""
    @Published public private(set) var fetchState: YouTubePatternAddFetchState = .idle
    @Published public private(set) var isAdding = false
    @Published public private(set) var addErrorKey: String?

    public let targetProjectID: UUID?
    private let thumbnailSanitizer: @Sendable (Data) throws -> Data
    private var parsedLink: YouTubePatternLink?
    private var metadataTask: Task<Void, Never>?
    private var activeRequestID = UUID()

    public init(
        targetProjectID: UUID? = nil,
        thumbnailSanitizer: @escaping @Sendable (Data) throws -> Data = {
            try PatternThumbnailFileService(directory: FileManager.default.temporaryDirectory)
                .sanitizedExternalThumbnailData($0)
        }
    ) {
        self.targetProjectID = targetProjectID
        self.thumbnailSanitizer = thumbnailSanitizer
    }

    deinit {
        metadataTask?.cancel()
    }

    public var isAddEnabled: Bool {
        canonicalLink != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func readMetadata(
        using fetcher: any YouTubePatternMetadataFetching,
        timeout: Duration = .seconds(10)
    ) {
        cancelMetadataRequest()
        addErrorKey = nil
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = try? YouTubePatternLink(parsing: url) else {
            parsedLink = nil
            fetchState = .manualEntry(messageKey: "patterns.youtube.invalidLink")
            return
        }

        parsedLink = link
        fetchState = .loading
        let requestID = UUID()
        activeRequestID = requestID
        metadataTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let metadata = try await withYouTubeMetadataTimeout(timeout: timeout) {
                    try await fetcher.fetch(for: link.canonicalURL)
                }
                guard !Task.isCancelled, activeRequestID == requestID, parsedLink == link else { return }
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let fetchedTitle = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !fetchedTitle.isEmpty {
                    title = fetchedTitle
                }
                let safeThumbnail = metadata.thumbnailData.flatMap { try? thumbnailSanitizer($0) }
                fetchState = .loaded(thumbnailData: safeThumbnail)
            } catch is CancellationError {
                // URL changes and view dismissal deliberately leave no error.
            } catch {
                guard activeRequestID == requestID, parsedLink == link else { return }
                fetchState = .manualEntry(messageKey: "patterns.youtube.metadataUnavailable")
            }
            guard activeRequestID == requestID else { return }
            metadataTask = nil
        }
    }

    public func cancelMetadataRequest() {
        activeRequestID = UUID()
        metadataTask?.cancel()
        metadataTask = nil
    }

    public func add(
        add: @escaping @MainActor @Sendable (YouTubePatternLink, String, UUID?) async throws -> YouTubePatternAddResult,
        cache: @escaping @MainActor @Sendable (Data, UUID) async -> Void
    ) async -> YouTubePatternAddResult? {
        guard !isAdding,
              let link = canonicalLink,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        isAdding = true
        addErrorKey = nil
        defer { isAdding = false }

        let thumbnailData: Data?
        if case let .loaded(data) = fetchState {
            thumbnailData = data
        } else {
            thumbnailData = nil
        }
        do {
            let result = try await add(link, title, targetProjectID)
            if let thumbnailData {
                await cache(thumbnailData, result.patternID)
            }
            return result
        } catch {
            addErrorKey = "patterns.youtube.addFailed"
            return nil
        }
    }

    func setPreviewThumbnailData(_ data: Data?) {
        fetchState = .loaded(thumbnailData: data)
    }

    private var canonicalLink: YouTubePatternLink? {
        if let parsedLink { return parsedLink }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return try? YouTubePatternLink(parsing: url)
    }
}

private actor YouTubeMetadataTimeoutRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func start(
        continuation: CheckedContinuation<Value, Error>,
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) {
        guard !finished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        operationTask = Task { @MainActor [weak self] in
            do {
                let value = try await operation()
                await self?.finish(.success(value))
            } catch {
                await self?.finish(.failure(error))
            }
        }
        // Do not inherit the main-actor caller's executor for the deadline.
        // A LinkPresentation provider can remain suspended forever, and the
        // timeout has to be able to win even while UI work is busy.
        timeoutTask = Task.detached { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                await self?.finish(.failure(YouTubeMetadataFetchError.timedOut))
            } catch is CancellationError {
                // The operation won the race.
            } catch {
                await self?.finish(.failure(error))
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Value, Error>) {
        guard !finished else { return }
        finished = true
        operationTask?.cancel()
        timeoutTask?.cancel()
        let continuation = continuation
        self.continuation = nil
        switch result {
        case let .success(value): continuation?.resume(returning: value)
        case let .failure(error): continuation?.resume(throwing: error)
        }
    }
}
