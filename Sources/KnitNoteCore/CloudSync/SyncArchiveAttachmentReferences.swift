import Foundation

/// Shared domain-to-slot authority for publication and migration export.
struct SyncArchiveAttachmentReferences {
    let photoService: ProjectPhotoFileService
    let yarnPhotoService: YarnPhotoFileService
    let yarnLabelPhotoService: YarnLabelPhotoFileService
    let journalPhotoService: ProjectJournalPhotoFileService
    let patternFileService: PatternFileService
    let patternMarkupFileService: PatternMarkupFileService

    init(liveRoot: URL) {
        photoService = .init(directory: liveRoot.appendingPathComponent("ProjectPhotos"))
        yarnPhotoService = .init(directory: liveRoot.appendingPathComponent("YarnPhotos"))
        yarnLabelPhotoService = .init(directory: liveRoot.appendingPathComponent("YarnLabelPhotos"))
        journalPhotoService = .init(directory: liveRoot.appendingPathComponent("ProjectJournalPhotos"))
        patternFileService = .init(root: liveRoot.appendingPathComponent("Patterns"))
        patternMarkupFileService = .init(root: liveRoot.appendingPathComponent("Patterns"))
    }

    init(photoService: ProjectPhotoFileService, yarnPhotoService: YarnPhotoFileService,
         yarnLabelPhotoService: YarnLabelPhotoFileService, journalPhotoService: ProjectJournalPhotoFileService,
         patternFileService: PatternFileService, patternMarkupFileService: PatternMarkupFileService) {
        self.photoService = photoService
        self.yarnPhotoService = yarnPhotoService
        self.yarnLabelPhotoService = yarnLabelPhotoService
        self.journalPhotoService = journalPhotoService
        self.patternFileService = patternFileService
        self.patternMarkupFileService = patternMarkupFileService
    }

    func references(
        in archive: ProjectArchive
    ) throws -> [SyncAttachmentReference] {
        var result: [SyncAttachmentReference] = []

        func add(
            owner: SyncEntityID,
            role: String,
            slotID: String,
            sourceURL: URL,
            displayFilename: String,
            fallbackMediaType: String
        ) {
            result.append(SyncAttachmentReference(
                slot: .init(owner: owner, role: role, slotID: slotID),
                sourceURL: sourceURL,
                mediaType: syncMediaType(
                    for: displayFilename,
                    fallback: fallbackMediaType
                ),
                displayFilename: displayFilename
            ))
        }

        for project in archive.projects {
            let projectOwner = SyncEntityID(kind: .project, uuid: project.id)
            if let filename = project.photoFilename {
                add(
                    owner: projectOwner,
                    role: "project-photo",
                    slotID: "primary",
                    sourceURL: photoService.url(filename: filename),
                    displayFilename: filename,
                    fallbackMediaType: "image/jpeg"
                )
            }
            for pattern in project.patterns {
                add(
                    owner: .init(kind: .pattern, uuid: pattern.id),
                    role: "legacy-pattern-source",
                    slotID: "project:\(project.id.uuidString)/source",
                    sourceURL: patternFileService.url(projectID: project.id, pattern: pattern),
                    displayFilename: pattern.storedFilename,
                    fallbackMediaType: "application/octet-stream"
                )
            }
            for entry in project.journalEntries {
                for (role, filename) in [
                    ("journal-photo", entry.photoFilename),
                    ("journal-thumbnail", entry.thumbnailFilename)
                ] {
                    guard let sourceURL = journalPhotoService.url(filename: filename) else {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                    add(
                        owner: .init(kind: .journalEntry, uuid: entry.id),
                        role: role,
                        slotID: "primary",
                        sourceURL: sourceURL,
                        displayFilename: filename,
                        fallbackMediaType: "image/jpeg"
                    )
                }
            }
        }
        for yarn in archive.yarns {
            let owner = SyncEntityID(kind: .yarn, uuid: yarn.id)
            if let filename = yarn.photoFilename {
                add(
                    owner: owner,
                    role: "yarn-photo",
                    slotID: "primary",
                    sourceURL: yarnPhotoService.url(filename: filename),
                    displayFilename: filename,
                    fallbackMediaType: "image/jpeg"
                )
            }
            for (filename, slotID) in zip(yarn.labelPhotoFilenames, yarn.labelPhotoSlotIDs) {
                guard let sourceURL = yarnLabelPhotoService.url(filename: filename) else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                add(
                    owner: owner,
                    role: "yarn-label-photo",
                    slotID: "label:\(slotID.uuidString.lowercased())",
                    sourceURL: sourceURL,
                    displayFilename: filename,
                    fallbackMediaType: "image/jpeg"
                )
            }
        }
        if !archive.patterns.isEmpty {
            let assetsByID = Dictionary(uniqueKeysWithValues: archive.patternAssets.map {
                ($0.id, $0)
            })
            let files = patternFileService
            for pattern in archive.patterns {
                guard let asset = assetsByID[pattern.assetID] else {
                    continue
                }
                add(
                    owner: .init(kind: .pattern, uuid: pattern.id),
                    role: "pattern-source",
                    slotID: "source",
                    sourceURL: try files.assetURL(asset),
                    displayFilename: asset.storedFilename,
                    fallbackMediaType: "application/octet-stream"
                )
            }
        }
        for usage in archive.patternUsages {
            for page in try patternMarkupFileService.usageMarkupPageIndices(usageID: usage.id) {
                add(owner: .init(kind: .patternUsage, uuid: usage.id),
                    role: "pattern-markup", slotID: "page:\(page)",
                    sourceURL: try patternMarkupFileService.usagePageURL(usageID: usage.id, pageIndex: page),
                    displayFilename: "\(page).json", fallbackMediaType: "application/json")
            }
        }
        for project in archive.projects {
            for pattern in project.patterns {
                for page in try patternMarkupFileService.legacyMarkupPageIndices(projectID: project.id, patternID: pattern.id) {
                    add(owner: .init(kind: .pattern, uuid: pattern.id),
                        role: "legacy-pattern-markup", slotID: "project:\(project.id.uuidString)/page:\(page)",
                        sourceURL: try patternMarkupFileService.legacyPageURL(projectID: project.id, patternID: pattern.id, pageIndex: page),
                        displayFilename: "\(page).json", fallbackMediaType: "application/json")
                }
            }
        }
        return result
    }
}

