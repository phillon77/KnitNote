import Foundation
import Security

/// Tests inject these three calls; constructing the live adapter performs no I/O.
protocol CloudRecoverySecurityCalls: Sendable {
    func add(_ query: [String: Any]) -> OSStatus
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct LiveCloudRecoverySecurityCalls: CloudRecoverySecurityCalls {
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

struct CloudRecoveryVaultKeychain: SyncRecoveryVaultKeychain {
    struct Failure: Error, Equatable { let status: OSStatus }
    private let calls: any CloudRecoverySecurityCalls
    init(calls: any CloudRecoverySecurityCalls = LiveCloudRecoverySecurityCalls()) { self.calls = calls }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.phillon.KnitNote.sealed-account-recovery.v1",
         kSecAttrAccount as String: id.uuidString.lowercased(),
         kSecAttrSynchronizable as String: false]
    }
    func insert(_ key: Data, for vaultID: UUID) throws {
        guard key.count == 32 else { throw SyncRecoveryVaultError.invalidPayload }
        var value = query(vaultID)
        value[kSecValueData as String] = key
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = calls.add(value)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
    func key(for vaultID: UUID) throws -> Data? {
        var value = query(vaultID)
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = calls.copy(value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data, data.count == 32 else { throw SyncRecoveryVaultError.authenticationFailed }
        return data
    }
    func remove(for vaultID: UUID) throws {
        let status = calls.delete(query(vaultID))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
