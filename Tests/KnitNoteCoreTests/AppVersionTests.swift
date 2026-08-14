import Testing
@testable import KnitNoteCore

@Suite struct AppVersionTests {
    @Test func parsesNormalizesAndOrdersReleaseVersions() throws {
        let v150 = try #require(AppVersion("1.5"))
        let v150Canonical = try #require(AppVersion("1.5.0"))
        let v152 = try #require(AppVersion("1.5.2"))
        let v151 = try #require(AppVersion("1.5.1"))
        let v160 = try #require(AppVersion("1.6"))
        let v1599 = try #require(AppVersion("1.5.99"))
        let v200 = try #require(AppVersion("2.0"))
        let v19999 = try #require(AppVersion("1.99.99"))

        #expect(v150 == v150Canonical)
        #expect(v152 > v151)
        #expect(v160 > v1599)
        #expect(v200 > v19999)
    }

    @Test func rejectsMalformedPrereleaseOverflowAndWrongArity() {
        for raw in ["", "1", "1.", ".1", "1..2", "1.2.3.4", "1.5-beta", " 1.5", "1. 5", "+1.5", "-1.5", "184467440737095516160.1"] {
            #expect(AppVersion(raw) == nil, "must reject \(raw)")
        }
    }
}
