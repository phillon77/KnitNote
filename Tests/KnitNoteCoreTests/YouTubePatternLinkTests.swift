import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct YouTubePatternLinkTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=31",
        "https://youtu.be/dQw4w9WgXcQ?si=abc",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/live/dQw4w9WgXcQ?feature=share",
    ])
    func supportedFormsCanonicalize(_ rawValue: String) throws {
        let link = try YouTubePatternLink(parsing: #require(URL(string: rawValue)))
        #expect(link.videoID == "dQw4w9WgXcQ")
        #expect(link.canonicalURL.absoluteString ==
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test(arguments: [
        "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/watch?v=",
        "https://example.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/not-valid",
    ])
    func unsafeOrUnsupportedLinksAreRejected(_ rawValue: String) throws {
        #expect(throws: YouTubePatternLinkError.self) {
            try YouTubePatternLink(parsing: #require(URL(string: rawValue)))
        }
    }
}
