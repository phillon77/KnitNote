import Foundation

/// Coordinates a library-row thumbnail refresh without letting stale or
/// cancelled work publish a result back to the row.
@MainActor
public final class YouTubePatternThumbnailLoader {
    public typealias CachedThumbnailURL = @MainActor @Sendable (UUID) async -> URL?
    public typealias LinkForPattern = @MainActor @Sendable (UUID) throws -> YouTubePatternLink
    public typealias CacheThumbnail = @MainActor @Sendable (Data, UUID) async -> Void
    public typealias IsCurrentYouTubeAsset = @MainActor @Sendable (UUID, UUID) async -> Bool

    private let fetcher: any YouTubePatternMetadataFetching
    private let cachedThumbnailURL: CachedThumbnailURL
    private let linkForPattern: LinkForPattern
    private let cacheThumbnail: CacheThumbnail
    private let isCurrentYouTubeAsset: IsCurrentYouTubeAsset

    public init(
        fetcher: any YouTubePatternMetadataFetching,
        cachedThumbnailURL: @escaping CachedThumbnailURL,
        linkForPattern: @escaping LinkForPattern,
        cacheThumbnail: @escaping CacheThumbnail,
        isCurrentYouTubeAsset: @escaping IsCurrentYouTubeAsset
    ) {
        self.fetcher = fetcher
        self.cachedThumbnailURL = cachedThumbnailURL
        self.linkForPattern = linkForPattern
        self.cacheThumbnail = cacheThumbnail
        self.isCurrentYouTubeAsset = isCurrentYouTubeAsset
    }

    /// Returns an existing cache immediately. When absent, it fetches artwork
    /// at utility priority, forwards cancellation to that fetch, and only
    /// rereads the cache while the requested pattern still owns the same asset.
    public func thumbnailURL(patternID: UUID, assetID: UUID) async -> URL? {
        if let cachedURL = await cachedThumbnailURL(patternID) {
            return cachedURL
        }
        guard let link = try? linkForPattern(patternID), !Task.isCancelled else {
            return nil
        }

        let metadataTask = Task(priority: .utility) { @MainActor [fetcher] in
            try? await fetcher.fetch(for: link.canonicalURL)
        }
        let metadata = await withTaskCancellationHandler {
            await metadataTask.value
        } onCancel: {
            metadataTask.cancel()
        }
        guard !Task.isCancelled,
              let thumbnailData = metadata?.thumbnailData else {
            return nil
        }

        await cacheThumbnail(thumbnailData, patternID)
        guard !Task.isCancelled,
              await isCurrentYouTubeAsset(patternID, assetID) else {
            return nil
        }
        return await cachedThumbnailURL(patternID)
    }
}
