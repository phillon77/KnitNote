import CloudKit

enum CloudAccountIdentityResult: Equatable, Sendable {
    case confirmed(CloudAccountBinding)
    case noAccount
    case unknown
}

struct CloudAccountIdentityQuery: Sendable {
    private let containerIdentifier: String
    private let accountStatus: @Sendable () async throws -> CKAccountStatus
    private let userRecordName: @Sendable () async throws -> String

    init(
        containerIdentifier: String,
        accountStatus: @escaping @Sendable () async throws -> CKAccountStatus,
        userRecordName: @escaping @Sendable () async throws -> String
    ) {
        self.containerIdentifier = containerIdentifier
        self.accountStatus = accountStatus
        self.userRecordName = userRecordName
    }

    func query() async -> CloudAccountIdentityResult {
        do {
            let status = try await accountStatus()
            guard !Task.isCancelled else { return .unknown }

            switch status {
            case .available:
                do {
                    let recordName = try await userRecordName()
                    guard !Task.isCancelled else { return .unknown }
                    guard let binding = try? CloudAccountBinding(
                        containerIdentifier: containerIdentifier,
                        userRecordName: recordName
                    ) else {
                        return .unknown
                    }
                    return .confirmed(binding)
                } catch {
                    return .unknown
                }
            case .noAccount:
                return .noAccount
            case .restricted, .couldNotDetermine, .temporarilyUnavailable:
                return .unknown
            @unknown default:
                return .unknown
            }
        } catch {
            return .unknown
        }
    }

    static func live(containerIdentifier: String) -> CloudAccountIdentityQuery {
        let container = CKContainer(identifier: containerIdentifier)
        return CloudAccountIdentityQuery(
            containerIdentifier: containerIdentifier,
            accountStatus: { try await container.accountStatus() },
            userRecordName: { try await container.userRecordID().recordName }
        )
    }
}
