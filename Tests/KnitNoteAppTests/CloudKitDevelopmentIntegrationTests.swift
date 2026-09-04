import CloudKit
import Foundation
import Security
import Testing

private enum CloudKitDevelopmentGateError: Error, Equatable {
    case productionEnvironmentRefused
}

private enum CloudKitDevelopmentGate {
    static let runVariable = "KNITNOTE_RUN_CLOUDKIT_INTEGRATION"
    static let environmentVariable = "KNITNOTE_CLOUDKIT_ENVIRONMENT"

    static func evaluate(
        environment: [String: String],
        containerIdentifier: String?,
        availability: @escaping @Sendable (String) async throws -> Bool
    ) async throws -> Bool {
        guard environment[runVariable] == "1" else { return false }

        let marker = environment[environmentVariable]?.lowercased()
        guard marker != "production" else {
            throw CloudKitDevelopmentGateError.productionEnvironmentRefused
        }
        guard marker == "development",
              let containerIdentifier,
              !containerIdentifier.isEmpty else {
            return false
        }
        return try await availability(containerIdentifier)
    }

    static func configuredContainerIdentifier() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "KnitNoteCloudKitContainerIdentifier") as? String
    }

    static func liveDevelopmentContainerIsAvailable() async throws -> Bool {
        try await evaluate(
            environment: ProcessInfo.processInfo.environment,
            containerIdentifier: configuredContainerIdentifier()
        ) { identifier in
            guard let signedEnvironment = signedEntitlement(
                "com.apple.developer.icloud-container-environment"
            ) as? String else {
                return false
            }
            guard signedEnvironment.lowercased() != "production" else {
                throw CloudKitDevelopmentGateError.productionEnvironmentRefused
            }
            guard signedEnvironment.lowercased() == "development",
                  let signedContainers = signedEntitlement(
                      "com.apple.developer.icloud-container-identifiers"
                  ) as? [String],
                  signedContainers.contains(identifier) else {
                return false
            }

            let container = CKContainer(identifier: identifier)
            do {
                return try await container.accountStatus() == .available
            } catch {
                return false
            }
        }
    }

    private static func signedEntitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }
}

private enum CloudKitDevelopmentProbe {
    static func run(
        zoneID: CKRecordZone.ID,
        createZone: () async throws -> Void,
        exerciseRecord: () async throws -> Void,
        deleteZone: (CKRecordZone.ID) async throws -> Void
    ) async throws {
        do {
            try await createZone()
            try await exerciseRecord()
        } catch {
            _ = try? await deleteZone(zoneID)
            throw error
        }
        try await deleteZone(zoneID)
    }
}

@Suite struct CloudKitDevelopmentIntegrationTests {
    private enum ProbeError: Error, Equatable { case create, record, cleanup }

    @Test func successfulProbeCleansUpTheExactZoneOnce() async throws {
        let chosen = uniqueProbeZoneID()
        let recorder = ProbeCleanupRecorder()

        try await CloudKitDevelopmentProbe.run(
            zoneID: chosen,
            createZone: {},
            exerciseRecord: {},
            deleteZone: { await recorder.append($0) }
        )

        #expect(await recorder.values == [chosen])
    }

    @Test func recordFailureCleansUpOnceAndPreservesThePrimaryFailure() async {
        let chosen = uniqueProbeZoneID()
        let recorder = ProbeCleanupRecorder()
        do {
            try await CloudKitDevelopmentProbe.run(
                zoneID: chosen,
                createZone: {},
                exerciseRecord: { throw ProbeError.record },
                deleteZone: { await recorder.append($0) }
            )
            Issue.record("Expected record failure")
        } catch {
            #expect(error as? ProbeError == .record)
        }
        #expect(await recorder.values == [chosen])
    }

    @Test func cleanupFailureAfterSuccessfulRecordIsReportedWithoutRetry() async {
        let chosen = uniqueProbeZoneID()
        let recorder = ProbeCleanupRecorder()
        do {
            try await CloudKitDevelopmentProbe.run(
                zoneID: chosen,
                createZone: {},
                exerciseRecord: {},
                deleteZone: {
                    await recorder.append($0)
                    throw ProbeError.cleanup
                }
            )
            Issue.record("Expected cleanup failure")
        } catch {
            #expect(error as? ProbeError == .cleanup)
        }
        #expect(await recorder.values == [chosen])
    }

    @Test func recordFailureRemainsPrimaryWhenExactCleanupAlsoFails() async {
        let chosen = uniqueProbeZoneID()
        let recorder = ProbeCleanupRecorder()
        do {
            try await CloudKitDevelopmentProbe.run(
                zoneID: chosen,
                createZone: {},
                exerciseRecord: { throw ProbeError.record },
                deleteZone: {
                    await recorder.append($0)
                    throw ProbeError.cleanup
                }
            )
            Issue.record("Expected record failure")
        } catch {
            #expect(error as? ProbeError == .record)
        }
        #expect(await recorder.values == [chosen])
    }

    @Test func ambiguousCreateFailureStillDeletesOnlyTheExactChosenZone() async {
        let chosen = CKRecordZone.ID(
            zoneName: "KnitNoteDevelopmentIntegration-\(UUID().uuidString)",
            ownerName: CKCurrentUserDefaultName
        )
        let defaultZone = CKRecordZone.default().zoneID
        let recorder = ProbeCleanupRecorder()

        do {
            try await CloudKitDevelopmentProbe.run(
                zoneID: chosen,
                createZone: {
                    throw CKError(.networkFailure)
                },
                exerciseRecord: {
                    Issue.record("record work must not run after ambiguous create failure")
                },
                deleteZone: { zoneID in
                    await recorder.append(zoneID)
                }
            )
            Issue.record("Expected the ambiguous create failure")
        } catch {
            #expect((error as? CKError)?.code == .networkFailure)
        }

        let deleted = await recorder.values
        #expect(deleted == [chosen])
        #expect(!deleted.contains(defaultZone))
    }

    @Test func productionMarkerIsRejectedBeforeContainerAccess() async {
        do {
            _ = try await CloudKitDevelopmentGate.evaluate(
                environment: [
                    CloudKitDevelopmentGate.runVariable: "1",
                    CloudKitDevelopmentGate.environmentVariable: "Production",
                ],
                containerIdentifier: "iCloud.example.invalid"
            ) { _ in
                Issue.record("The production refusal must happen before CKContainer access")
                return true
            }
            Issue.record("Expected the production environment marker to be refused")
        } catch {
            #expect(error as? CloudKitDevelopmentGateError == .productionEnvironmentRefused)
        }
    }

    @Test func missingOptInSkipsBeforeContainerAccess() async throws {
        let enabled = try await CloudKitDevelopmentGate.evaluate(
            environment: [:],
            containerIdentifier: "iCloud.example.invalid"
        ) { _ in
            Issue.record("The default-off gate must not access CKContainer")
            return true
        }

        #expect(!enabled)
    }

    @Test(
        .enabled("NOT RUN unless explicitly opted into an available Development container") {
            try await CloudKitDevelopmentGate.liveDevelopmentContainerIsAvailable()
        }
    )
    func createsFetchesUpdatesAndDeletesUniqueDevelopmentZone() async throws {
        // Recheck the environment before constructing CKContainer in the test body.
        let environment = ProcessInfo.processInfo.environment
        guard environment[CloudKitDevelopmentGate.environmentVariable]?.lowercased() != "production" else {
            throw CloudKitDevelopmentGateError.productionEnvironmentRefused
        }
        let identifier = try #require(CloudKitDevelopmentGate.configuredContainerIdentifier())
        let database = CKContainer(identifier: identifier).privateCloudDatabase
        let suffix = UUID().uuidString.lowercased()
        let zoneID = CKRecordZone.ID(
            zoneName: "KnitNoteDevelopmentIntegration-\(suffix)",
            ownerName: CKCurrentUserDefaultName
        )
        try await CloudKitDevelopmentProbe.run(
            zoneID: zoneID,
            createZone: {
                _ = try await database.save(CKRecordZone(zoneID: zoneID))
            },
            exerciseRecord: {
            let recordID = CKRecord.ID(recordName: "probe-\(suffix)", zoneID: zoneID)
            let record = CKRecord(recordType: "KnitNoteDevelopmentIntegrationProbe", recordID: recordID)
            record["sequence"] = 1 as NSNumber
            record["createdAt"] = Date() as NSDate
            _ = try await database.save(record)

            let fetched = try await database.record(for: recordID)
            #expect((fetched["sequence"] as? NSNumber)?.intValue == 1)

            fetched["sequence"] = 2 as NSNumber
            _ = try await database.save(fetched)
            let updated = try await database.record(for: recordID)
            #expect((updated["sequence"] as? NSNumber)?.intValue == 2)
            },
            deleteZone: { exactZoneID in
                _ = try await database.deleteRecordZone(withID: exactZoneID)
            }
        )
    }
}

private func uniqueProbeZoneID() -> CKRecordZone.ID {
    CKRecordZone.ID(
        zoneName: "KnitNoteDevelopmentIntegration-\(UUID().uuidString)",
        ownerName: CKCurrentUserDefaultName
    )
}

private actor ProbeCleanupRecorder {
    private(set) var values: [CKRecordZone.ID] = []

    func append(_ value: CKRecordZone.ID) {
        values.append(value)
    }
}
