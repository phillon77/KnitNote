import Foundation
import LinkPresentation
import UniformTypeIdentifiers

struct YouTubeLinkMetadata: Sendable {
    let title: String?
    let thumbnailData: Data?
}

@MainActor
protocol YouTubeLinkMetadataFetching {
    func fetch(for url: URL) async throws -> YouTubeLinkMetadata
}

@MainActor
final class LiveYouTubeLinkMetadataFetcher: YouTubeLinkMetadataFetching {
    func fetch(for url: URL) async throws -> YouTubeLinkMetadata {
        let providerBox = MetadataProviderBox(provider: LPMetadataProvider())
        return try await withTaskCancellationHandler {
            let metadata = try await providerBox.provider.startFetchingMetadata(for: url)
            let thumbnailData: Data?
            if let imageProvider = metadata.imageProvider {
                thumbnailData = await withCheckedContinuation { continuation in
                    imageProvider.loadDataRepresentation(
                        forTypeIdentifier: UTType.image.identifier
                    ) { data, _ in
                        continuation.resume(returning: data)
                    }
                }
            } else {
                thumbnailData = nil
            }
            return YouTubeLinkMetadata(
                title: metadata.title,
                thumbnailData: thumbnailData
            )
        } onCancel: {
            Task { @MainActor in
                providerBox.provider.cancel()
            }
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

enum YouTubeMetadataFetchError: Error {
    case timedOut
}

@MainActor
func withYouTubeMetadataTimeout<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            throw YouTubeMetadataFetchError.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
