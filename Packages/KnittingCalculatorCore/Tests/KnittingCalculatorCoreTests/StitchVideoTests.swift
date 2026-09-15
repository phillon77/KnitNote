import Foundation
import Testing
@testable import KnittingCalculatorCore

struct StitchVideoTests {
    @Test func everyBundledStitchHasAnExplicitVideoTutorial() throws {
        let url = try #require(StitchDictionaryResources.url(named: "stitch-dictionary-v1"))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sources = try #require(json["sources"] as? [[String: Any]])
        let entries = try #require(json["entries"] as? [[String: Any]])
        let videos = Set(sources.filter { ($0["videoLanguage"] as? String)?.isEmpty == false }.compactMap { $0["id"] as? String })
        for entry in entries {
            let ids = try #require(entry["sourceIDs"] as? [String])
            #expect(!videos.isDisjoint(with: ids), "Missing video for \(entry["id"] ?? "unknown")")
        }
    }
}
