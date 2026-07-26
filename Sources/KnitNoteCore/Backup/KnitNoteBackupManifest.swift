import Foundation

public struct KnitNoteBackupManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 2
    public static let fileIntegrityFeature = "data-file-sha256"

    public let formatVersion: Int
    public let createdAt: Date
    public let appVersion: String
    public let projectCount: Int
    public let yarnCount: Int
    public let patternCount: Int?
    public let files: [KnitNoteBackupManifestFile]
    public let criticalFeatures: [String]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        createdAt: Date,
        appVersion: String,
        projectCount: Int,
        yarnCount: Int,
        patternCount: Int? = nil,
        files: [KnitNoteBackupManifestFile] = [],
        criticalFeatures: [String] = []
    ) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.projectCount = projectCount
        self.yarnCount = yarnCount
        self.patternCount = patternCount
        self.files = files
        self.criticalFeatures = criticalFeatures
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case createdAt
        case appVersion
        case projectCount
        case yarnCount
        case patternCount
        case files
        case criticalFeatures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        projectCount = try container.decode(Int.self, forKey: .projectCount)
        yarnCount = try container.decode(Int.self, forKey: .yarnCount)
        patternCount = try container.decodeIfPresent(Int.self, forKey: .patternCount)
        files = try container.decodeIfPresent(
            [KnitNoteBackupManifestFile].self,
            forKey: .files
        ) ?? []
        criticalFeatures = try container.decodeIfPresent(
            [String].self,
            forKey: .criticalFeatures
        ) ?? []
    }

    public func preview() throws -> KnitNoteBackupPreview {
        guard formatVersion <= Self.currentFormatVersion else {
            throw KnitNoteBackupError.unsupportedNewerVersion(formatVersion)
        }
        guard projectCount >= 0, yarnCount >= 0 else {
            throw KnitNoteBackupError.invalidManifest
        }
        let knownCriticalFeatures = Set([Self.fileIntegrityFeature])
        guard Set(criticalFeatures).isSubset(of: knownCriticalFeatures) else {
            throw KnitNoteBackupError.invalidManifest
        }
        switch formatVersion {
        case 1:
            return KnitNoteBackupPreview(
                createdAt: createdAt,
                projectCount: projectCount,
                yarnCount: yarnCount,
                patternCount: nil
            )
        case 2:
            guard let patternCount,
                  patternCount >= 0,
                  criticalFeatures.contains(Self.fileIntegrityFeature) else {
                throw KnitNoteBackupError.invalidManifest
            }
            return KnitNoteBackupPreview(
                createdAt: createdAt,
                projectCount: projectCount,
                yarnCount: yarnCount,
                patternCount: patternCount
            )
        default:
            throw KnitNoteBackupError.invalidManifest
        }
    }
}

public struct KnitNoteBackupManifestFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String

    public init(relativePath: String, byteCount: Int64, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct KnitNoteBackupPreview: Equatable, Sendable {
    public let createdAt: Date
    public let projectCount: Int
    public let yarnCount: Int
    public let patternCount: Int?

    public init(
        createdAt: Date,
        projectCount: Int,
        yarnCount: Int,
        patternCount: Int? = nil
    ) {
        self.createdAt = createdAt
        self.projectCount = projectCount
        self.yarnCount = yarnCount
        self.patternCount = patternCount
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
    case integrityMismatch(String)
    case invalidMarkup
    case fileTooLarge
    case packageTooLarge
    case accessDenied
    case operationInProgress
    case crossVolumeReplacement
    case installFailedOriginalPreserved
    case rollbackFailed
}
