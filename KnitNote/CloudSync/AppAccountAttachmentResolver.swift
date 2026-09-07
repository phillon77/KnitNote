import Foundation

/// Resolves immutable bytes through their existing owners. A partial fetched
/// batch has no authority to decide which concurrent head can be omitted.
@MainActor struct AppAccountAttachmentResolver {
    let account: SyncAccountIdentity
    let installedDownload: (SyncAttachmentVersion) throws -> URL
    let validateOwnership: () throws -> Void

    func canonical(records: [SyncRecord], references: [SyncAttachmentReference], pending: [SyncMutation],
        bootstrap: SyncCanonicalBootstrapHandoff?) throws -> [UUID: SyncAttachmentSource] {
        try validateOwnership()
        let records = try SyncRecordValidator().validate(records)
        let lineage = try SyncAttachmentLineage(records: records)
        let byID = lineage.recordsByVersionID
        let required = Set(lineage.headsBySlot.values.flatMap { $0 }.filter { $0.deletedAt.value == nil }.map(\.id.uuid))
        let displayed = lineage.resolvedLiveVersionIDs()
        var sources: [UUID: SyncAttachmentSource] = [:]
        for mutation in pending {
            guard case let .save(save) = try mutation.validated(), let source = save.attachmentSource,
                  let version = save.recordVersion.record.payload.attachment else { continue }
            try verify(source, version: version)
            guard let current = byID[version.versionID] else { continue }
            guard try SyncAttachmentImmutableSnapshot(record: current)
                == SyncAttachmentImmutableSnapshot(record: save.recordVersion.record) else {
                throw SyncPublicationError.corruptTransaction
            }
            // Multiple valid sends may own distinct staged files for the same
            // immutable version. Verify each, then retain one original object;
            // activation independently validates every pending send as well.
            if sources[version.versionID] == nil { sources[version.versionID] = source }
        }
        for id in required.sorted(by: { $0.uuidString < $1.uuidString }) where sources[id] == nil {
            guard let version = byID[id]?.payload.attachment else { throw SyncPublicationError.corruptTransaction }
            try requireBound(version)
            if displayed[version.slot] == id {
                let selected = references.filter { normalized($0.slot) == normalized(version.slot) }
                guard selected.count <= 1 else { throw SyncPublicationError.corruptTransaction }
                if let reference = selected.first {
                    let source = try source(at: reference.sourceURL, version: version)
                    try verify(source, version: version)
                    sources[id] = source
                    continue
                }
            }
            if let bootstrap {
                guard bootstrap.accountIDHash == account.accountIDHash else { throw SyncPublicationError.corruptTransaction }
                if let source = try bootstrap.stagedAttachmentSource(version) {
                    try verify(source, version: version)
                    sources[id] = source
                    continue
                }
            }
            try validateOwnership()
            let source = try source(at: installedDownload(version), version: version)
            try verify(source, version: version)
            sources[id] = source
        }
        try validateOwnership()
        return sources
    }

    func fetched(batch: SyncRemoteBatch) throws -> [UUID: SyncAttachmentSource] {
        try validateOwnership()
        guard batch.identity.accountIDHash == account.accountIDHash else { throw SyncRemoteBatchError.missingAuthority }
        let records = try SyncRecordValidator().validate(batch.records)
        var sources: [UUID: SyncAttachmentSource] = [:]
        for record in records where record.id.kind == .attachment && record.deletedAt.value == nil {
            guard let version = record.payload.attachment, record.id.uuid == version.versionID else {
                throw SyncPublicationError.corruptTransaction
            }
            try requireBound(version)
            try validateOwnership()
            let source = try source(at: installedDownload(version), version: version)
            try verify(source, version: version)
            sources[version.versionID] = source
        }
        try validateOwnership()
        return sources
    }

    private func source(at url: URL, version: SyncAttachmentVersion) throws -> SyncAttachmentSource {
        try requireBound(version)
        return try .init(fileURL: url, contentSHA256: version.contentSHA256, byteCount: version.byteCount)
    }

    func verify(_ source: SyncAttachmentSource, version: SyncAttachmentVersion) throws {
        try validateOwnership()
        try requireBound(version)
        guard source.contentSHA256 == version.contentSHA256, source.byteCount == version.byteCount else {
            throw SyncPublicationError.corruptTransaction
        }
        _ = try SyncRegularFileReader().read(source.fileURL, maximumBytes: 100_000_000,
            expected: .init(byteCount: version.byteCount, sha256: version.contentSHA256))
        try validateOwnership()
    }

    private func requireBound(_ version: SyncAttachmentVersion) throws {
        guard (0...100_000_000).contains(version.byteCount) else { throw SyncRegularFileReadError.tooLarge }
    }

    private func normalized(_ slot: SyncAttachmentSlot) -> SyncAttachmentSlot {
        let role: String
        switch slot.role {
        case "usage-markup": role = "pattern-markup"
        case "legacy-markup": role = "legacy-pattern-markup"
        default: role = slot.role
        }
        return .init(owner: slot.owner, role: role, slotID: slot.slotID)
    }
}
