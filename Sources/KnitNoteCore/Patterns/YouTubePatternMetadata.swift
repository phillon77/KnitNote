import Foundation

public enum YouTubePatternMetadataError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidLink
}

public struct YouTubePatternMetadata: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let videoID: String
    public let canonicalURL: URL

    public init(link: YouTubePatternLink) {
        version = Self.currentVersion
        videoID = link.videoID
        canonicalURL = link.canonicalURL
    }

    public func validated() throws -> YouTubePatternLink {
        guard version == Self.currentVersion else {
            throw YouTubePatternMetadataError.unsupportedVersion
        }
        let link = try YouTubePatternLink(videoID: videoID)
        guard link.canonicalURL == canonicalURL else {
            throw YouTubePatternMetadataError.invalidLink
        }
        return link
    }
}
