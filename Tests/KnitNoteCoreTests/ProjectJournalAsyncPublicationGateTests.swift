import Testing
@testable import KnitNoteCore

@Suite struct ProjectJournalAsyncPublicationGateTests {
    @Test func cancellationInvalidatesLatePublication() {
        var gate = ProjectJournalAsyncPublicationGate()
        let revision = gate.begin()

        gate.cancel()

        let didPublish = gate.finish(revision)
        #expect(!didPublish)
        #expect(!gate.isActive)
    }

    @Test func supersededOperationCannotPublishIntoTheNewOperation() {
        var gate = ProjectJournalAsyncPublicationGate()
        let staleRevision = gate.begin()
        let currentRevision = gate.begin()

        let staleDidPublish = gate.finish(staleRevision)
        #expect(!staleDidPublish)
        #expect(gate.isActive)
        let currentDidPublish = gate.finish(currentRevision)
        #expect(currentDidPublish)
        #expect(!gate.isActive)
    }
}
