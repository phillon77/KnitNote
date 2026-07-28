import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderContextTests {
    @Test func readOnlyContextHasNoWritableUsage() {
        let patternID = UUID()

        let context = PatternReaderContext.readOnly(patternID: patternID)

        #expect(context.patternID == patternID)
        #expect(context.usageID == nil)
        #expect(context.projectID == nil)
        #expect(!context.canWrite)
    }

    @Test func activeProjectContextWritesOnlyThroughItsOwnUsage() {
        let patternID = UUID()
        let usageID = UUID()
        let projectID = UUID()

        let context = PatternReaderContext.project(
            patternID: patternID,
            usageID: usageID,
            projectID: projectID,
            projectIsCompleted: false
        )

        #expect(context.patternID == patternID)
        #expect(context.usageID == usageID)
        #expect(context.projectID == projectID)
        #expect(context.canWrite)
    }

    @Test func completedProjectContextCannotWrite() {
        let context = PatternReaderContext.project(
            patternID: UUID(),
            usageID: UUID(),
            projectID: UUID(),
            projectIsCompleted: true
        )

        #expect(!context.canWrite)
    }

    @Test func inactiveUsageContextCannotWrite() {
        let context = PatternReaderContext.project(
            patternID: UUID(),
            usageID: UUID(),
            projectID: UUID(),
            usageIsActive: false,
            projectIsCompleted: false
        )

        #expect(!context.usageIsActive)
        #expect(!context.canWrite)
    }

    @Test func entitlementLockedProjectContextIsReadOnlyButCanRequestUnlock() {
        let context = PatternReaderContext.project(
            patternID: UUID(),
            usageID: UUID(),
            projectID: UUID(),
            projectIsCompleted: false,
            entitlementCanWrite: false
        )

        #expect(!context.entitlementCanWrite)
        #expect(!context.canWrite)
        #expect(context.canRequestUnlock)
    }

    @Test func structurallyReadOnlyContextsNeverRequestUnlock() {
        let completed = PatternReaderContext.project(
            patternID: UUID(),
            usageID: UUID(),
            projectID: UUID(),
            projectIsCompleted: true,
            entitlementCanWrite: false
        )

        #expect(!PatternReaderContext.readOnly(patternID: UUID()).canRequestUnlock)
        #expect(!completed.canRequestUnlock)
    }
}
