import Darwin
import Foundation

public enum SyncInstallationIdentityError: Error, Equatable, Sendable {
    case corrupt
    case unsafeFile
}

public final class SyncInstallationIdentityStore: @unchecked Sendable {
    private static let currentVersion = 1
    private static let sharedLock = NSLock()

    private struct Envelope: Codable {
        let version: Int
        let identity: String
    }

    private let url: URL
    private let beforeCreate: (() throws -> Void)?

    public init(url: URL) {
        self.url = url
        beforeCreate = nil
    }

    init(url: URL, beforeCreate: @escaping () throws -> Void) {
        self.url = url
        self.beforeCreate = beforeCreate
    }

    public func loadOrCreate() throws -> String {
        Self.sharedLock.lock()
        defer { Self.sharedLock.unlock() }

        var didInvokeCreateHook = false
        while true {
            switch try existingIdentity() {
            case let .some(identity):
                return identity
            case .none:
                if !didInvokeCreateHook {
                    try beforeCreate?()
                    didInvokeCreateHook = true
                }
                let identity = UUID().uuidString
                let data: Data
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    data = try encoder.encode(Envelope(
                        version: Self.currentVersion,
                        identity: identity
                    ))
                } catch {
                    throw SyncInstallationIdentityError.corrupt
                }
                if try SyncDurableFile.createNoClobber(data, at: url) {
                    return identity
                }
            }
        }
    }

    private func existingIdentity() throws -> String? {
        var status = stat()
        let lstatResult = url.path.withCString { Darwin.lstat($0, &status) }
        if lstatResult != 0 {
            guard errno == ENOENT else { throw SyncInstallationIdentityError.unsafeFile }
            return nil
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw SyncInstallationIdentityError.unsafeFile
        }
        let data: Data
        do {
            data = try SyncDurableFile.readRegularFile(at: url)
        } catch let error as SyncDurableFileError {
            throw error == .unsafeFile
                ? SyncInstallationIdentityError.unsafeFile
                : SyncInstallationIdentityError.corrupt
        } catch {
            throw SyncInstallationIdentityError.corrupt
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Self.currentVersion,
                  UUID(uuidString: envelope.identity) != nil else {
                throw SyncInstallationIdentityError.corrupt
            }
            return envelope.identity
        } catch let error as SyncInstallationIdentityError {
            throw error
        } catch {
            throw SyncInstallationIdentityError.corrupt
        }
    }
}
