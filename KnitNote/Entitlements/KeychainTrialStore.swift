import Foundation
import Security

public struct KeychainTrialStore: TrialStore {
    struct SecurityClient: @unchecked Sendable {
        static let live = Self(
            copyMatching: SecItemCopyMatching,
            add: SecItemAdd
        )

        let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    }

    private static let service = "com.phillon.KnitNote.trial"
    private static let account = "trial-record-v1"
    private let securityClient: SecurityClient

    public init() {
        securityClient = .live
    }

    init(securityClient: SecurityClient) {
        self.securityClient = securityClient
    }

    public func load() throws -> TrialRecord? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = securityClient.copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainTrialStoreError.missingRecordData
            }
            let record = try Self.decoder.decode(TrialRecord.self, from: data)
            guard record.version == 1 else {
                throw KeychainTrialStoreError.unsupportedRecordVersion(record.version)
            }
            return record
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainTrialStoreError.unexpectedStatus(status)
        }
    }

    public func startIfNeeded(now: Date) throws -> TrialRecord {
        if let existing = try load() {
            return existing
        }

        let candidate = TrialRecord(startedAt: now)
        let data = try Self.encoder.encode(candidate)
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]
        let status = securityClient.add(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return candidate
        case errSecDuplicateItem:
            guard let existing = try load() else {
                throw KeychainTrialStoreError.duplicateItemWithoutRecord
            }
            return existing
        default:
            throw KeychainTrialStoreError.unexpectedStatus(status)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public enum KeychainTrialStoreError: Error, Equatable {
    case missingRecordData
    case unsupportedRecordVersion(Int)
    case duplicateItemWithoutRecord
    case unexpectedStatus(OSStatus)
}
