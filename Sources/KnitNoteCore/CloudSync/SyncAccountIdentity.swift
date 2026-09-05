import CryptoKit
import Foundation

/// Stable namespace for one container and the exact CloudKit user record name.
/// Raw identifiers are deliberately not retained, encoded, or exposed to reflection.
/// This v1 format is not the legacy asset store's single-string account token.
public struct SyncAccountIdentity: Hashable, Sendable, CustomStringConvertible {
    public let accountIDHash: String
    public var description: String { "SyncAccountIdentity(\(accountIDHash))" }

    public init(containerIdentifier: String, userRecordName: String) throws {
        guard !containerIdentifier.isEmpty, !userRecordName.isEmpty else {
            throw SyncAccountStorageError.invalidIdentity
        }
        var bytes = Data("KnitNote.SyncAccountIdentity.v1\0".utf8)
        // Length framing prevents delimiter/boundary collisions. Use original UTF-8:
        // do not trim, case-fold or normalize the server's opaque record name.
        for field in [containerIdentifier, userRecordName] {
            let value = Data(field.utf8)
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(value)
        }
        accountIDHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
