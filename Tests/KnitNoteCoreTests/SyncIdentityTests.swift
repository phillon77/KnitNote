import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncIdentityTests {
    @Test func mutationStampUsesLogicalRevisionBeforeClockAndDevice() throws {
        let older = SyncMutationStamp(logicalRevision: 3, modifiedAt: .distantFuture, deviceID: "z")
        let newer = SyncMutationStamp(logicalRevision: 4, modifiedAt: .distantPast, deviceID: "a")

        #expect(older < newer)
        #expect(try JSONDecoder().decode(SyncMutationStamp.self, from: JSONEncoder().encode(newer)) == newer)
    }

    @Test func mutationStampUsesClockThenDeviceWhenRevisionsMatch() {
        let earlier = SyncMutationStamp(logicalRevision: 7, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "z")
        let later = SyncMutationStamp(logicalRevision: 7, modifiedAt: Date(timeIntervalSince1970: 2), deviceID: "a")
        #expect(earlier < later)

        let deviceA = SyncMutationStamp(logicalRevision: 7, modifiedAt: Date(timeIntervalSince1970: 2), deviceID: "a")
        let deviceB = SyncMutationStamp(logicalRevision: 7, modifiedAt: Date(timeIntervalSince1970: 2), deviceID: "b")
        #expect(deviceA < deviceB)
    }

    @Test func identityAndFieldVersionRoundTripThroughCodable() throws {
        let identity = SyncEntityID(kind: .projectCounter, uuid: UUID())
        let stamp = SyncMutationStamp(logicalRevision: 12, modifiedAt: Date(timeIntervalSince1970: 42), deviceID: "iphone")
        let version = SyncFieldVersion(value: 17, stamp: stamp)

        let decodedIdentity = try JSONDecoder().decode(SyncEntityID.self, from: JSONEncoder().encode(identity))
        let decodedVersion = try JSONDecoder().decode(SyncFieldVersion<Int>.self, from: JSONEncoder().encode(version))
        #expect(decodedIdentity == identity)
        #expect(decodedVersion == version)
    }

    @Test func entityKindsContainAllSyncEntities() {
        #expect(SyncEntityKind.allCases.count == 13)
        #expect(SyncEntityKind(rawValue: "deletionMarker") == .deletionMarker)
        #expect(SyncEntityKind(rawValue: "watchCommandProof") == .watchCommandProof)
    }
}
