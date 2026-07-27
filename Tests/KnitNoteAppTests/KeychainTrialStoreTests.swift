import Foundation
import Security
import Testing
@testable import KnitNote

@Suite struct KeychainTrialStoreTests {
    @Test func validExistingRecordIsReturnedWithoutAdding() throws {
        let script = SecurityScript(copyResponses: [
            .init(status: errSecSuccess, data: validRecordData(startedAtMilliseconds: 1_000_000)),
        ])
        let store = KeychainTrialStore(securityClient: script.client)

        let result = try store.startIfNeeded(now: Date(timeIntervalSince1970: 9_000))

        #expect(result == TrialRecord(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(script.copyQueries.count == 1)
        #expect(script.addAttributes.isEmpty)
    }

    @Test func missingRecordAddsCanonicalMillisecondsPayload() throws {
        let script = SecurityScript(
            copyResponses: [.init(status: errSecItemNotFound)],
            addStatuses: [errSecSuccess]
        )
        let store = KeychainTrialStore(securityClient: script.client)

        let result = try store.startIfNeeded(now: Date(timeIntervalSince1970: 1_234.5))

        #expect(result == TrialRecord(startedAt: Date(timeIntervalSince1970: 1_234.5)))
        let query = try #require(script.copyQueries.only)
        #expect(query.count == 5)
        #expect(cfEqual(query[kSecClass], kSecClassGenericPassword))
        #expect(query[kSecAttrService] as? String == "com.phillon.KnitNote.trial")
        #expect(query[kSecAttrAccount] as? String == "trial-record-v1")
        #expect(cfEqual(query[kSecMatchLimit], kSecMatchLimitOne))
        #expect(query[kSecReturnData] as? Bool == true)

        let attributes = try #require(script.addAttributes.only)
        #expect(attributes.count == 5)
        #expect(cfEqual(attributes[kSecClass], kSecClassGenericPassword))
        #expect(attributes[kSecAttrService] as? String == "com.phillon.KnitNote.trial")
        #expect(attributes[kSecAttrAccount] as? String == "trial-record-v1")
        #expect(cfEqual(attributes[kSecAttrAccessible], kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly))
        let data = try #require(attributes[kSecValueData] as? Data)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload.count == 2)
        #expect(payload["version"] as? Int == 1)
        #expect(payload["startedAt"] as? Double == 1_234_500)
    }

    @Test func duplicateAddReturnsTheFreshlyReadWinningRecord() throws {
        let script = SecurityScript(
            copyResponses: [
                .init(status: errSecItemNotFound),
                .init(status: errSecSuccess, data: validRecordData(startedAtMilliseconds: 2_000_000)),
            ],
            addStatuses: [errSecDuplicateItem]
        )
        let store = KeychainTrialStore(securityClient: script.client)

        let result = try store.startIfNeeded(now: Date(timeIntervalSince1970: 9_000))

        #expect(result == TrialRecord(startedAt: Date(timeIntervalSince1970: 2_000)))
        #expect(script.copyQueries.count == 2)
        #expect(script.addAttributes.count == 1)
    }

    @Test(arguments: InvalidRecordFixture.allCases)
    func invalidInitialRecordFailsClosedWithoutAdding(_ fixture: InvalidRecordFixture) throws {
        let script = SecurityScript(copyResponses: [
            .init(status: errSecSuccess, data: fixture.data),
        ])
        let store = KeychainTrialStore(securityClient: script.client)

        switch fixture {
        case .malformed:
            #expect(throws: DecodingError.self) {
                _ = try store.startIfNeeded(now: Date(timeIntervalSince1970: 9_000))
            }
        case .unsupported:
            #expect(throws: KeychainTrialStoreError.unsupportedRecordVersion(2)) {
                _ = try store.startIfNeeded(now: Date(timeIntervalSince1970: 9_000))
            }
        }
        #expect(script.copyQueries.count == 1)
        #expect(script.addAttributes.isEmpty)
    }

    @Test(arguments: InvalidRecordFixture.allCases)
    func invalidDuplicateWinnerFailsClosedAfterTheSingleAtomicAdd(_ fixture: InvalidRecordFixture) throws {
        let script = SecurityScript(
            copyResponses: [
                .init(status: errSecItemNotFound),
                .init(status: errSecSuccess, data: fixture.data),
            ],
            addStatuses: [errSecDuplicateItem]
        )
        let store = KeychainTrialStore(securityClient: script.client)

        switch fixture {
        case .malformed:
            #expect(throws: DecodingError.self) {
                _ = try store.startIfNeeded(now: Date(timeIntervalSince1970: 9_000))
            }
        case .unsupported:
            #expect(throws: KeychainTrialStoreError.unsupportedRecordVersion(2)) {
                _ = try store.startIfNeeded(now: Date(timeIntervalSince1970: 9_000))
            }
        }
        #expect(script.copyQueries.count == 2)
        #expect(script.addAttributes.count == 1)
    }
}

enum InvalidRecordFixture: CaseIterable, Sendable {
    case malformed
    case unsupported

    var data: Data {
        switch self {
        case .malformed:
            return Data(#"{"version":1,"startedAt":"not-a-date"}"#.utf8)
        case .unsupported:
            return Data(#"{"version":2,"startedAt":1000000}"#.utf8)
        }
    }
}

private final class SecurityScript: @unchecked Sendable {
    struct CopyResponse {
        let status: OSStatus
        let data: Data?

        init(status: OSStatus, data: Data? = nil) {
            self.status = status
            self.data = data
        }
    }

    private var remainingCopyResponses: [CopyResponse]
    private var remainingAddStatuses: [OSStatus]
    private(set) var copyQueries: [[CFString: Any]] = []
    private(set) var addAttributes: [[CFString: Any]] = []

    init(copyResponses: [CopyResponse], addStatuses: [OSStatus] = []) {
        remainingCopyResponses = copyResponses
        remainingAddStatuses = addStatuses
    }

    var client: KeychainTrialStore.SecurityClient {
        .init(
            copyMatching: { [self] query, result in
                copyQueries.append(query as NSDictionary as! [CFString: Any])
                let response = remainingCopyResponses.removeFirst()
                result?.pointee = response.data.map { $0 as CFData }
                return response.status
            },
            add: { [self] attributes, _ in
                addAttributes.append(attributes as NSDictionary as! [CFString: Any])
                return remainingAddStatuses.removeFirst()
            }
        )
    }
}

private func validRecordData(startedAtMilliseconds: Int) -> Data {
    Data(#"{"version":1,"startedAt":\#(startedAtMilliseconds)}"#.utf8)
}

private func cfEqual(_ actual: Any?, _ expected: CFTypeRef) -> Bool {
    guard let actual else { return false }
    return CFEqual(actual as CFTypeRef, expected)
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
