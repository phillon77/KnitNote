import CloudKit
import Testing
@testable import KnitNote

@Suite struct CloudAccountIdentityQueryTests {
    @Test func availableAccountWithRecordNameConfirmsBinding() async throws {
        let query = CloudAccountIdentityQuery(
            containerIdentifier: "test.container",
            accountStatus: { .available },
            userRecordName: { "account-A" }
        )

        #expect(await query.query() == .confirmed(try CloudAccountBinding(
            containerIdentifier: "test.container",
            userRecordName: "account-A"
        )))
    }

    @Test func noAccountDoesNotLookUpRecordIdentity() async {
        let probe = IdentityQueryProbe()
        let query = CloudAccountIdentityQuery(
            containerIdentifier: "test.container",
            accountStatus: { .noAccount },
            userRecordName: { await probe.recordLookup(returning: "must-not-be-used") }
        )

        #expect(await query.query() == .noAccount)
        #expect(await probe.recordLookupCount == 0)
    }

    @Test(arguments: [
        CKAccountStatus.restricted,
        .couldNotDetermine,
        .temporarilyUnavailable,
    ])
    func ambiguousStatusDoesNotLookUpRecordIdentity(status: CKAccountStatus) async {
        let probe = IdentityQueryProbe()
        let query = CloudAccountIdentityQuery(
            containerIdentifier: "test.container",
            accountStatus: { status },
            userRecordName: { await probe.recordLookup(returning: "must-not-be-used") }
        )

        #expect(await query.query() == .unknown)
        #expect(await probe.recordLookupCount == 0)
    }

    @Test func accountStatusErrorIsUnknownWithoutRecordLookup() async {
        let probe = IdentityQueryProbe()
        let query = CloudAccountIdentityQuery(
            containerIdentifier: "test.container",
            accountStatus: { throw IdentityQueryTestError.injected },
            userRecordName: { await probe.recordLookup(returning: "must-not-be-used") }
        )

        #expect(await query.query() == .unknown)
        #expect(await probe.recordLookupCount == 0)
    }

    @Test func availableIdentityLookupErrorIsUnknown() async {
        let denied = CloudAccountIdentityQuery(
            containerIdentifier: "test.container",
            accountStatus: { .available },
            userRecordName: { throw CKError(.notAuthenticated) }
        )

        #expect(await denied.query() == .unknown)
    }

    @Test func emptyContainerIdentifierNeverConfirms() async {
        let query = CloudAccountIdentityQuery(
            containerIdentifier: "",
            accountStatus: { .available },
            userRecordName: { "account-A" }
        )

        #expect(await query.query() == .unknown)
    }

    @Test func emptyRecordNameNeverConfirms() async {
        let query = CloudAccountIdentityQuery(
            containerIdentifier: "test.container",
            accountStatus: { .available },
            userRecordName: { "" }
        )

        #expect(await query.query() == .unknown)
    }

    @Test func cancellationAfterStatusAwaitCannotConfirmNoAccount() async {
        let status = IdentityQueryGate<CKAccountStatus>()
        let probe = IdentityQueryProbe()
        let query = CloudAccountIdentityQuery(
            containerIdentifier: "test.container",
            accountStatus: { await status.wait() },
            userRecordName: { await probe.recordLookup(returning: "must-not-be-used") }
        )
        let task = Task { await query.query() }
        await status.waitUntilEntered()

        task.cancel()
        await status.release(returning: .noAccount)

        #expect(await task.value == .unknown)
        #expect(await probe.recordLookupCount == 0)
    }

    @Test func cancellationAfterRecordAwaitCannotConfirmAccount() async {
        let recordName = IdentityQueryGate<String>()
        let query = CloudAccountIdentityQuery(
            containerIdentifier: "test.container",
            accountStatus: { .available },
            userRecordName: { await recordName.wait() }
        )
        let task = Task { await query.query() }
        await recordName.waitUntilEntered()

        task.cancel()
        await recordName.release(returning: "account-A")

        #expect(await task.value == .unknown)
    }
}

private enum IdentityQueryTestError: Error {
    case injected
}

private actor IdentityQueryProbe {
    private(set) var recordLookupCount = 0

    func recordLookup(returning value: String) -> String {
        recordLookupCount += 1
        return value
    }
}

private actor IdentityQueryGate<Value: Sendable> {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release(returning value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
