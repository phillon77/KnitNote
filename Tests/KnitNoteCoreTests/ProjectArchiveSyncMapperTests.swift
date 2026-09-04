import Foundation
import Testing
@testable import KnitNoteCore

struct ProjectArchiveSyncMapperTests {
    @Test func cachedBootstrapIssuesEveryUnissuedAttachmentWithoutResettingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: root)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
        var cached = try SyncCanonicalPublicationSnapshot(archive: archive, deviceID: "test").records
        let projectID = SyncEntityID(kind: .project, uuid: archive.projects[0].id)
        var projectRecord = cached[projectID]!
        projectRecord.entityRevision = 99
        cached[projectID] = projectRecord
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test",
            reusing: .init(archive: archive, records: cached), issuedAttachmentRecords: [])
        #expect(package.attachments.count == 6)
        #expect(try package.record(for: projectID) == projectRecord)
        let result = try ProjectArchiveSyncMapper.materialize(records: package.records,
            attachments: stage(package, root: root), baseArchive: .init(version: 14, projects: []))
        #expect(result.archive.projects == archive.projects)
    }

    @Test func invalidCounterOrdinalsCannotTriggerDomainDecoderNormalization() throws {
        let project = try StoredProject(name: "Counters")
        let archive = ProjectArchive(version: 14, projects: [project])
        let original = try SyncCanonicalPublicationSnapshot(archive: archive, deviceID: "test").records.values
        for ordinals in [[1, 1, 1, 1, 1, 1], [0, 2, 3, 4, 5, 6], [1, 2, 3, 4, 5, 7]] {
            let changed = original.map { record -> SyncRecord in
                guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else { return record }
                var record = record
                let counter = ProjectCounter(id: state.counter.id,
                    defaultOrdinal: ordinals[state.counter.defaultOrdinal - 1], value: 17)
                record.payload.atomicDomain = .init(value: .projectCounter(.init(counter: counter,
                    reminders: [], preparedCommand: nil, processedCommandIDs: [], occurrence: nil)),
                    stamp: record.payload.atomicDomain!.stamp)
                return record
            }
            _ = try SyncRecordValidator().validate(changed)
            #expect(throws: (any Error).self) {
                try ProjectArchiveSyncMapper.materialize(records: changed, attachments: [:], baseArchive: archive)
            }
        }
    }

    @Test func concurrentAttachmentHeadsSurviveMaterializationAndReexport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: root)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
        let first = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "a")
        let second = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "b")
        let history = first.records.filter { $0.id.kind == .attachment } + second.records.filter { $0.id.kind == .attachment }
        let merged = second.records.filter { $0.id.kind != .attachment } + history
        let result = try ProjectArchiveSyncMapper.materialize(records: merged,
            attachments: stage(second, root: root), baseArchive: archive)
        #expect(result.files.count == 6)
        #expect(Set(result.files.map { $0.version.versionID }) == Set(second.attachments.keys))
        for records in [history, history.reversed()] {
            let exported = try ProjectArchiveSyncMapper.export(archive: result.archive, liveRoot: root, deviceID: "b",
                reusing: .init(archive: result.archive, records: Dictionary(uniqueKeysWithValues: result.records.map { ($0.id, $0) })),
                issuedAttachmentRecords: records)
            #expect(exported.records.filter { $0.id.kind == .attachment }.count == 12)
            #expect(Set(exported.attachments.keys) == Set(second.attachments.keys))
            for record in history { #expect(try exported.record(for: record.id) == record) }
        }
    }

    @Test func exportRejectsCorruptDeclaredPatternAsset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writePatternLibraryArchive(to: root)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
        try Data("bad asset".utf8).write(to: root.appendingPathComponent("Patterns/Assets/\(archive.patternAssets[0].storedFilename)"))
        #expect(throws: (any Error).self) { try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test") }
    }

    @Test func tombstonesSurviveExportOfEmptyDomain() throws {
        let project = try StoredProject(name: "Deleted")
        var deleted = try #require(SyncCanonicalPublicationSnapshot(archive: .init(version: 14, projects: [project]), deviceID: "test").records[.init(kind: .project, uuid: project.id)])
        deleted.deletedAt = .init(value: Date(timeIntervalSinceReferenceDate: 100), stamp: deleted.deletedAt.stamp)
        let empty = ProjectArchive(version: 14, projects: [])
        let package = try ProjectArchiveSyncMapper.export(archive: empty, liveRoot: FileManager.default.temporaryDirectory, deviceID: "test", reusing: .init(archive: empty, records: [deleted.id: deleted]))
        #expect(package.records == [deleted])
    }

    @Test func unchangedCanonicalCachePreservesCausalRevision() throws {
        let project = try StoredProject(name: "Cached")
        let archive = ProjectArchive(version: 14, projects: [project])
        var records = try SyncCanonicalPublicationSnapshot(archive: archive, deviceID: "origin").records
        let id = SyncEntityID(kind: .project, uuid: project.id)
        var record = records[id]!
        let stamp = SyncMutationStamp(logicalRevision: 99, modifiedAt: Date(timeIntervalSinceReferenceDate: 999), deviceID: "origin")
        record.entityRevision = 99
        record.payload.fields = record.payload.fields.mapValues { .init(value: $0.value, stamp: stamp) }
        record.deletedAt = .init(value: nil, stamp: stamp)
        records[id] = record
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: FileManager.default.temporaryDirectory, deviceID: "origin", reusing: .init(archive: archive, records: records))
        #expect(try package.record(for: id) == record)
    }

    @Test func legacyDecodedVersionsKeepCounterIdentity() throws {
        for version in 1...14 {
            let id = UUID()
            let data = Data("""
                {"version":\(version),"projects":[{"id":"\(id.uuidString)","name":"Legacy","createdAt":0,"updatedAt":1,"currentRow":23,"rowNotes":[{"row":2,"text":"Cable","createdAt":0,"updatedAt":1}]}]}
                """.utf8)
            let archive = try JSONDecoder().decode(ProjectArchive.self, from: data)
            let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: FileManager.default.temporaryDirectory, deviceID: "test")
            let result = try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: [:], baseArchive: .init(version: 14, projects: []))
            #expect(result.archive.projects == archive.projects)
        }
    }

    @Test func localAuxiliaryAssetMetadataAndFilesRemainExplicit() throws {
        let asset = PatternAsset(sha256: "abc", kind: .pdf, storedFilename: "aux.pdf", byteCount: 3, pageCount: 1)
        let archive = ProjectArchive(version: 14, projects: [], patternAssets: [asset])
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: FileManager.default.temporaryDirectory, deviceID: "test")
        #expect(package.localOnlyPatternAssets == [asset])
        #expect(package.localOnlyRelativePaths == ["Patterns/Assets/aux.pdf"])
        #expect(package.records.isEmpty)
        let result = try ProjectArchiveSyncMapper.materialize(records: [], attachments: [:], baseArchive: archive)
        #expect(result.archive.patternAssets == [asset])
        #expect(result.localOnlyRelativePaths == ["Patterns/Assets/aux.pdf"])
    }

    @Test func orphanWatchProofIsRetainedAcrossMaterializationAndReexport() throws {
        let command = WatchCounterCommand(id: UUID(), projectID: UUID(), counterID: UUID(), operation: .increment, createdAt: .init(timeIntervalSince1970: 40))
        let proof = try SyncProcessedWatchCommandProof(id: command.id, rejection: .projectMissing,
            commandIdentity: .init(command), preparedCommand: nil, effectProof: nil,
            processingStamp: .init(logicalRevision: 0, modifiedAt: .init(timeIntervalSince1970: 41), deviceID: "test"))
        let archive = ProjectArchive(version: 14, projects: [])
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: FileManager.default.temporaryDirectory, deviceID: "test", processedWatchProofs: [proof])
        #expect(package.records.count == 1)
        let result = try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: [:], baseArchive: archive)
        #expect(result.records == package.records)
        let again = try ProjectArchiveSyncMapper.export(archive: result.archive, liveRoot: FileManager.default.temporaryDirectory, deviceID: "test",
            reusing: .init(archive: result.archive, records: Dictionary(uniqueKeysWithValues: result.records.map { ($0.id, $0) })))
        #expect(again.records == package.records)
    }

    @Test func foldersAndUsagePayloadMustMatchRequiredParents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writePatternLibraryArchive(to: root)
        var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
        let folder = PatternFolder(displayName: "Charts")
        archive.patternFolders = [folder]
        archive.patterns[0].folderID = folder.id
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test")
        let staged = try stage(package, root: root)
        let valid = try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: staged, baseArchive: .init(version: 14, projects: []))
        #expect(valid.archive.patternFolders == [folder])
        #expect(valid.archive.patterns == archive.patterns)
        #expect(throws: (any Error).self) {
            try ProjectArchiveSyncMapper.materialize(records: package.records.filter { $0.id.kind != .patternFolder }, attachments: staged, baseArchive: .init(version: 14, projects: []))
        }
    }

    @Test func unverifiedOriginalAndMissingSourcesCannotMaterialize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: root)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test")
        #expect(throws: (any Error).self) { try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: package.attachments, baseArchive: archive) }
        #expect(throws: (any Error).self) { try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: [:], baseArchive: archive) }
        #expect(throws: (any Error).self) { try ProjectArchiveSyncMapper.materialize(records: package.records + [package.records[0]], attachments: [:], baseArchive: archive) }
    }

    @Test func bootstrapAttachmentIDsBindBytesAndRetainIssuedVersions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: root)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
        let first = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test")
        let second = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test")
        #expect(first.records == second.records)
        let reused = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test",
            issuedAttachmentRecords: first.records.filter { $0.id.kind == .attachment })
        #expect(first.records == reused.records)
        let id = try #require(first.attachments.keys.first)
        try Data("changed bytes".utf8).write(to: first.attachments[id]!.fileURL)
        let changed = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test")
        #expect(changed.attachments[id] == nil)
    }

    @Test func sixCountersNotesAndReminderOrderRoundtrip() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let counters = (1...6).map { ProjectCounter(defaultOrdinal: $0, customName: "Counter \($0)", value: $0 * 4, mutationRevision: UInt64($0)) }
        let lateID = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        let earlyID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let reminders = try [lateID, earlyID].map { id in try #require(KnittingReminder(id: id, counterID: counters[0].id,
            draft: .oneTime(kind: .custom, target: 20, text: "Turn"), createdAt: now)) }
        var project = try StoredProject(name: "Notes", counters: counters, knittingReminders: reminders, now: now)
        for counter in counters { try project.saveNote(counterID: counter.id, row: 2, text: "Note \(counter.defaultOrdinal)", now: now) }
        let archive = ProjectArchive(version: 14, projects: [project])
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: FileManager.default.temporaryDirectory, deviceID: "test")
        let result = try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: [:], baseArchive: .init(version: 14, projects: []))
        #expect(result.archive.projects == archive.projects)
        #expect(result.counterStates.count == 6)
    }

    @Test func completeLegacyAndCurrentArchivesRoundtripWithoutMovingMedia() throws {
        for library in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            if library { _ = try BackupFixture.writePatternLibraryArchive(to: root, includeLinkedYarn: true) }
            else { _ = try BackupFixture.writeCompleteArchive(to: root) }
            let original = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
            let package = try ProjectArchiveSyncMapper.export(archive: original, liveRoot: root, deviceID: "test")
            #expect(package.attachments.count == (library ? 2 : 6))
            let result = try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: stage(package, root: root), baseArchive: .init(version: 14, projects: []))
            #expect(result.archive.projects == original.projects)
            #expect(result.archive.yarns == original.yarns)
            #expect(result.archive.patterns == original.patterns)
            #expect(result.archive.patternAssets == original.patternAssets)
            #expect(result.archive.patternUsages == original.patternUsages)
            #expect(result.files.count == package.attachments.count)
            for attachment in package.attachments.values {
                #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
            }
        }
    }

    @Test func sameNamesOnlyProduceHintsAndProviderIsImmutable() throws {
        let first = try StoredProject(name: "Cardigan")
        let second = try StoredProject(name: "Cardigan")
        let archive = ProjectArchive(version: 14, projects: [first, second])
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: FileManager.default.temporaryDirectory, deviceID: "test")
        #expect(package.possibleDuplicates.count == 1)
        let provider: any SyncRecordProvider = package
        #expect(try provider.record(for: .init(kind: .project, uuid: first.id)) != nil)
        let result = try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: [:], baseArchive: .init(version: 14, projects: []))
        #expect(Set(result.archive.projects.map(\.id)) == [first.id, second.id])
        #expect(result.archive.projects.allSatisfy { $0.counters.count == 6 })
        #expect(throws: (any Error).self) {
            try ProjectArchiveSyncMapper.materialize(records: package.records.filter { $0.id.kind != .project }, attachments: [:], baseArchive: archive)
        }
    }

    @Test func corruptedAttachmentBytesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: root)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "test")
        let staged = try stage(package, root: root)
        let source = try #require(staged.values.first)
        try Data("corrupt".utf8).write(to: source.fileURL)
        #expect(throws: (any Error).self) {
            try ProjectArchiveSyncMapper.materialize(records: package.records, attachments: staged, baseArchive: archive)
        }
    }

    private func stage(_ package: SyncExportPackage, root: URL) throws -> [UUID: SyncAttachmentSource] {
        try Dictionary(uniqueKeysWithValues: package.attachments.map { id, source in
            let url = root.appendingPathComponent("staged-\(id.uuidString)")
            try FileManager.default.copyItem(at: source.fileURL, to: url)
            return (id, SyncAttachmentSource(fileURL: url, contentSHA256: source.contentSHA256,
                byteCount: source.byteCount, isJournalStaged: true))
        })
    }
}
