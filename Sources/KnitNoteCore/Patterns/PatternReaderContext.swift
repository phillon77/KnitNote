import Foundation

/// Identifies whether a pattern is being read independently or through one
/// specific project usage. Reader writes must always use `usageID`, never the
/// pattern ID, because a pattern can be linked to more than one project.
public struct PatternReaderContext: Equatable, Hashable, Sendable {
    public let patternID: UUID
    public let usageID: UUID?
    public let projectID: UUID?
    public let projectIsCompleted: Bool

    private init(
        patternID: UUID,
        usageID: UUID?,
        projectID: UUID?,
        projectIsCompleted: Bool
    ) {
        self.patternID = patternID
        self.usageID = usageID
        self.projectID = projectID
        self.projectIsCompleted = projectIsCompleted
    }

    public static func readOnly(patternID: UUID) -> Self {
        .init(
            patternID: patternID,
            usageID: nil,
            projectID: nil,
            projectIsCompleted: false
        )
    }

    public static func project(
        patternID: UUID,
        usageID: UUID,
        projectID: UUID,
        projectIsCompleted: Bool
    ) -> Self {
        .init(
            patternID: patternID,
            usageID: usageID,
            projectID: projectID,
            projectIsCompleted: projectIsCompleted
        )
    }

    public var canWrite: Bool {
        usageID != nil && projectID != nil && !projectIsCompleted
    }
}
