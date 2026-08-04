import Foundation

public enum YouTubePatternLinkError: Error, Equatable, Sendable {
    case insecureURL
    case unsupportedHost
    case missingVideoID
    case invalidVideoID
}

public struct YouTubePatternLink: Codable, Equatable, Hashable, Sendable {
    public let videoID: String
    public let canonicalURL: URL

    public init(videoID: String) throws {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        guard videoID.count == 11,
              videoID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")
        else { throw YouTubePatternLinkError.invalidVideoID }
        self.videoID = videoID
        canonicalURL = url
    }

    public init(parsing url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw YouTubePatternLinkError.insecureURL
        }
        guard let host = url.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
                .contains(host) else {
            throw YouTubePatternLinkError.unsupportedHost
        }

        let path = url.pathComponents.filter { $0 != "/" }
        let videoID: String?
        if host == "youtu.be" {
            videoID = path.first
        } else if path.first == "watch" {
            videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
        } else if let first = path.first,
                  ["shorts", "live"].contains(first),
                  path.count >= 2 {
            videoID = path[1]
        } else {
            videoID = nil
        }
        guard let videoID, !videoID.isEmpty else {
            throw YouTubePatternLinkError.missingVideoID
        }
        try self.init(videoID: videoID)
    }
}
