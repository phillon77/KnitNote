import Foundation

public struct KnitNoteBackupManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let createdAt: Date
    public let appVersion: String
    public let projectCount: Int
    public let yarnCount: Int

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        createdAt: Date,
        appVersion: String,
        projectCount: Int,
        yarnCount: Int
    ) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.projectCount = projectCount
        self.yarnCount = yarnCount
    }

    public func preview() throws -> KnitNoteBackupPreview {
        guard formatVersion <= Self.currentFormatVersion else {
            throw KnitNoteBackupError.unsupportedNewerVersion(formatVersion)
        }
        guard formatVersion == 1, projectCount >= 0, yarnCount >= 0 else {
            throw KnitNoteBackupError.invalidManifest
        }
        return KnitNoteBackupPreview(
            createdAt: createdAt,
            projectCount: projectCount,
            yarnCount: yarnCount
        )
    }
}

public struct KnitNoteBackupPreview: Equatable, Sendable {
    public let createdAt: Date
    public let projectCount: Int
    public let yarnCount: Int

    public init(createdAt: Date, projectCount: Int, yarnCount: Int) {
        self.createdAt = createdAt
        self.projectCount = projectCount
        self.yarnCount = yarnCount
    }
}

public enum KnitNoteBackupLimits {
    public static let maximumManifestBytes: Int64 = 1_000_000
    public static let maximumArchiveBytes: Int64 = 20_000_000
    public static let maximumMarkupBytes: Int64 = 2_000_000
    public static let maximumMarkupEntriesPerPattern = 512
    public static let maximumMarkupStrokesPerDocument = 2_048
    public static let maximumMarkupPointsPerStroke = 10_000
    public static let maximumMarkupPointsPerDocument = 50_000
    public static let maximumFileBytes: Int64 = 200_000_000
    public static let maximumPackageBytes: Int64 = 4_000_000_000
}

public enum KnitNoteBackupError: Error, Equatable, Sendable {
    case invalidManifest
    case unsupportedNewerVersion(Int)
    case invalidArchive
    case countMismatch
    case duplicateIdentifier
    case invalidYarnProjectLinks
    case unsafePackageEntry
    case unknownPackageEntry
    case missingReferencedFile(String)
    case invalidMarkup
    case fileTooLarge
    case packageTooLarge
    case accessDenied
    case operationInProgress
    case crossVolumeReplacement
    case installFailedOriginalPreserved
    case rollbackFailed
}
