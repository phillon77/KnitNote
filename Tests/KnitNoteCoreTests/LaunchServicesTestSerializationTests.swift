import Foundation
import Testing

@Suite struct LaunchServicesTestSerializationTests {
    @Test func launchServicesCallersShareOneSerializationBoundary() throws {
        let targetContract = try readRepositoryFile(
            "Tests/KnitNoteCoreTests/ShareExtensionTargetContractTests.swift"
        )
        let sharePresentation = try readRepositoryFile(
            "Tests/KnitNoteCoreTests/PatternShareImportPresentationTests.swift"
        )

        #expect(
            targetContract.components(
                separatedBy: "LaunchServicesTestGate.withSerializedAccess"
            ).count - 1 == 1
        )
        #expect(
            sharePresentation.components(
                separatedBy: "LaunchServicesTestGate.withSerializedAccess"
            ).count - 1 == 4
        )
    }

    @Test func sharedGateAllowsOnlyOneConcurrentCriticalSection() async {
        let probe = CriticalSectionProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await LaunchServicesTestGate.withSerializedAccess {
                        probe.enter()
                        Thread.sleep(forTimeInterval: 0.002)
                        probe.leave()
                    }
                }
            }
        }

        #expect(probe.maximumConcurrentCount == 1)
    }
}

private final class CriticalSectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumCount = 0

    var maximumConcurrentCount: Int {
        lock.withLock { maximumCount }
    }

    func enter() {
        lock.withLock {
            activeCount += 1
            maximumCount = max(maximumCount, activeCount)
        }
    }

    func leave() {
        lock.withLock {
            activeCount -= 1
        }
    }
}
