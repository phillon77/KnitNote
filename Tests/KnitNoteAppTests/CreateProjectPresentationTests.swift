import Testing
@testable import KnitNote

@Suite struct CreateProjectPresentationTests {
    @Test func accessRestrictionRequestsUnlock() {
        #expect(
            CreateProjectFailureMapper.presentation(
                for: ProjectStoreError.accessRestricted
            ) == .requestUnlock
        )
    }

    @Test func persistenceFailureRemainsSaveError() {
        let result = CreateProjectFailureMapper.presentation(
            for: ProjectStoreError.persistenceFailed
        )
        guard case let .saveError(message) = result else {
            Issue.record("Expected save error")
            return
        }
        #expect(!message.isEmpty)
    }
}
