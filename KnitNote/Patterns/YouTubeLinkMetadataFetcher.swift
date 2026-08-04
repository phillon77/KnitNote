import Foundation
import LinkPresentation
import UniformTypeIdentifiers

@MainActor
final class LiveYouTubeLinkMetadataFetcher: YouTubePatternMetadataFetching {
    func fetch(for url: URL) async throws -> YouTubePatternPresentationMetadata {
        let providerBox = MetadataProviderBox(provider: LPMetadataProvider())
        return try await withTaskCancellationHandler {
            let metadata = try await providerBox.provider.startFetchingMetadata(for: url)
            let thumbnailData: Data?
            if let imageProvider = metadata.imageProvider {
                thumbnailData = try await loadImageData(from: imageProvider)
            } else {
                thumbnailData = nil
            }
            return YouTubePatternPresentationMetadata(
                title: metadata.title,
                thumbnailData: thumbnailData
            )
        } onCancel: {
            Task { @MainActor in
                providerBox.provider.cancel()
            }
        }
    }

    private func loadImageData(from provider: NSItemProvider) async throws -> Data? {
        let gate = ImageDataLoadGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let progress = provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.image.identifier
                ) { data, error in
                    if let data {
                        gate.resolve(.success(data))
                    } else if let error {
                        gate.resolve(.failure(error))
                    } else {
                        gate.resolve(.success(nil))
                    }
                }
                gate.setProgress(progress)
            }
        } onCancel: {
            gate.cancel()
        }
    }
}

@MainActor
private final class MetadataProviderBox {
    let provider: LPMetadataProvider

    init(provider: LPMetadataProvider) {
        self.provider = provider
    }
}

private final class ImageDataLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?
    private var progress: Progress?
    private var hasResolved = false

    func install(_ continuation: CheckedContinuation<Data?, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResolved else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
    }

    func setProgress(_ progress: Progress?) {
        lock.lock()
        defer { lock.unlock() }
        self.progress = progress
        if hasResolved { progress?.cancel() }
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    func resolve(_ result: Result<Data?, Error>) {
        lock.lock()
        guard !hasResolved else {
            lock.unlock()
            return
        }
        hasResolved = true
        progress?.cancel()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case let .success(data): continuation?.resume(returning: data)
        case let .failure(error): continuation?.resume(throwing: error)
        }
    }
}
