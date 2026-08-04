import Foundation
import Testing

@Suite struct AddYouTubePatternContractTests {
    @Test func metadataFetcherDefinesInjectableFetchAndTimeoutBoundaries() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/YouTubeLinkMetadataFetcher.swift")

        #expect(source.contains("protocol YouTubeLinkMetadataFetching"))
        #expect(source.contains("func fetch(for url: URL) async throws -> YouTubeLinkMetadata"))
        #expect(source.contains("@MainActor"))
        #expect(source.contains("withYouTubeMetadataTimeout"))
        #expect(source.contains("Task.sleep(for: .seconds(10))"))
        #expect(source.contains("provider.cancel()"))
    }

    @Test func addScreenKeepsAllFetchStatesAndAUserEditableFallback() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/AddYouTubePatternView.swift")

        #expect(source.contains("case idle"))
        #expect(source.contains("case loading"))
        #expect(source.contains("case loaded"))
        #expect(source.contains("case manualEntry"))
        #expect(source.contains("TextField(\"patterns.youtube.title\""))
        #expect(source.contains("patterns.youtube.metadataUnavailable"))
        #expect(source.contains("addIsEnabled"))
        #expect(source.contains(".disabled(!addIsEnabled"))
    }

    @Test func addScreenParsesBeforeFetchesAndCancelsTheCurrentRequest() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/AddYouTubePatternView.swift")
        let parser = try #require(source.range(of: "YouTubePatternLink(parsing:"))
        let fetch = try #require(source.range(of: "metadataFetcher.fetch(for:"))

        #expect(parser.lowerBound < fetch.lowerBound)
        #expect(source.contains("metadataTask?.cancel()"))
        #expect(source.contains(".onDisappear"))
        #expect(source.contains("cancelMetadataRequest()"))
    }

    @Test func addScreenAddsOnePatternBeforeBestEffortCachingAndReturnsItsResolution() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/AddYouTubePatternView.swift")
        let add = try #require(source.range(of: "store.addYouTubePattern("))
        let cache = try #require(source.range(of: "store.cacheYouTubeThumbnail("))

        #expect(add.lowerBound < cache.lowerBound)
        #expect(source.contains("targetProjectID"))
        #expect(source.contains("onFinished(result.patternID, result.resolution)"))
    }
}
