import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnitNoteBackupPackagePlanTests {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func frozen(_ package: BackupFixture.Package) throws -> KnitNoteBackupFrozenTree {
        // Normalize both sides: FileManager may enumerate /private/var for a /var root.
        let root = package.url.appendingPathComponent("Data").resolvingSymlinksInPath()
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        var directories = Set<String>(), files: [String: SyncBootstrapOutputProof] = [:]
        for case let url as URL in enumerator {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { directories.insert(path) }
            else {
                let bytes = try Data(contentsOf: url)
                files[path] = .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
            }
        }
        return .init(archiveData: try Data(contentsOf: root.appendingPathComponent("projects-v1.json")), directories: directories, files: files)
    }
    private func plan(_ package: BackupFixture.Package, _ tree: KnitNoteBackupFrozenTree,
        cap: Int = 100_000_000) throws -> KnitNoteBackupPackagePlan {
        try package.service.planOwnedPackage(source: tree, role: .validationMerged, packageID: id,
            accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
            transactionID: id, appVersion: "1.2.0", now: Date(timeIntervalSince1970: 20),
            maximumMetadataBytes: cap, temporaryID: { _ in id })
    }

    @Test(arguments: [false, true]) func matchesActualHelperFilesAndManifest(library: Bool) throws {
        let f = try library ? BackupFixture.patternLibraryPackage() : BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        let ordinary = try f.service.createPackage(appVersion: "1.2.0", now: Date(timeIntervalSince1970: 20))
        let before = try BackupFixture.childNames(in: f.service.workRoot)
        let p = try plan(f, tree)
        #expect(try BackupFixture.childNames(in: f.service.workRoot) == before)
        #expect(p.archiveData == tree.archiveData)
        let ordinaryManifest = try Data(contentsOf: ordinary.appendingPathComponent("manifest.json"))
        #expect(p.manifestData == ordinaryManifest)
        #expect(p.sourceFiles[f.markupRelativePath] == tree.files[f.markupRelativePath])
        let manifest = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: p.manifestData)
        #expect(Set(manifest.files.map(\.relativePath)) == Set(tree.files.keys))
        var writes: [String: SyncBootstrapOutputProof] = [:]
        for action in p.actions {
            if case let .write(_, path, .create(proof), _) = action { writes[path] = proof }
        }
        let package = id.uuidString + ".knitnote-backup"
        #expect(writes.count == tree.files.count + 1)
        for (path, proof) in tree.files { #expect(writes[package + "/Data/" + path] == proof) }
        #expect(writes[package + "/manifest.json"]?.sha256 == Data(SHA256.hash(data: p.manifestData)))
        #expect(p.temporaryIDs.count == writes.count)
        try f.service.validateFrozenPackageSource(p, source: tree)
        _ = try plan(f, tree, cap: p.output.reservedEncodedEntryBytes)
        #expect(throws: SyncBootstrapOutputPlanner.Error.tooLarge) { try plan(f, tree, cap: p.output.reservedEncodedEntryBytes - 1) }
    }

    @Test func changedSelectedProofAndNewMarkupInvalidatePlan() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f), p = try plan(f, tree)
        var changed = tree.files
        let old = try #require(changed[f.firstRelativePath])
        changed[f.firstRelativePath] = .init(byteCount: old.byteCount, sha256: Data(repeating: 9, count: 32))
        #expect(throws: KnitNoteBackupError.self) {
            try f.service.validateFrozenPackageSource(p, source: .init(archiveData: tree.archiveData, directories: tree.directories, files: changed))
        }
        var extra = tree.files
        let owner = f.markupRelativePath.split(separator: "/").dropLast().joined(separator: "/")
        extra[owner + "/9999.json"] = .init(byteCount: 2, sha256: Data(repeating: 8, count: 32))
        #expect(throws: KnitNoteBackupError.self) {
            try f.service.validateFrozenPackageSource(p, source: .init(archiveData: tree.archiveData, directories: tree.directories, files: extra))
        }
        #expect(throws: KnitNoteBackupError.self) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories.subtracting([owner]), files: tree.files))
        }
    }

    @Test func unknownMarkupAndOversizeProofFailWithoutOutputs() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        let before = try BackupFixture.childNames(in: f.service.workRoot)
        var files = tree.files
        files[f.firstRelativePath] = .init(byteCount: 100_000_001, sha256: Data(repeating: 1, count: 32))
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
        let owner = f.markupRelativePath.split(separator: "/").dropLast().joined(separator: "/")
        files = tree.files; files[owner + "/unexpected.bin"] = .init(byteCount: 1, sha256: Data(repeating: 2, count: 32))
        #expect(throws: KnitNoteBackupError.unknownPackageEntry) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
        #expect(try BackupFixture.childNames(in: f.service.workRoot) == before)
    }
}

extension KnitNoteBackupPackagePlanTests {
    @Test func packageLimitIncludesManifestBeforeTemporaryCallbacks() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        var projects: [StoredProject] = []
        var files: [String: SyncBootstrapOutputProof] = [:]
        var lastPath = ""
        for index in 0..<40 {
            var project = try StoredProject(name: "Photo")
            let name = project.id.uuidString + "-" + UUID().uuidString + ".jpg"
            project.setPhotoFilename(name)
            projects.append(project)
            lastPath = "ProjectPhotos/" + name
            files[lastPath] = .init(byteCount: index == 39 ? 90_000_000 : 100_000_000,
                sha256: Data(repeating: 1, count: 32))
        }
        let bytes = try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: projects, yarns: []))
        files["projects-v1.json"] = .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
        let initial = try plan(f, .init(archiveData: bytes, directories: ["ProjectPhotos"], files: files))
        // Both last-file counts have eight digits, so the manifest's encoded length stays fixed.
        let lastBytes = 100_000_000 - Int64(bytes.count) - Int64(initial.manifestData.count)
        files[lastPath] = .init(byteCount: lastBytes, sha256: Data(repeating: 1, count: 32))
        let exact = try plan(f, .init(archiveData: bytes, directories: ["ProjectPhotos"], files: files))
        #expect(exact.sourceFiles.values.reduce(Int64(exact.manifestData.count)) { $0 + $1.byteCount } == 4_000_000_000)
        files[lastPath] = .init(byteCount: lastBytes + 1, sha256: Data(repeating: 1, count: 32))
        var callbackCount = 0
        #expect(throws: KnitNoteBackupError.packageTooLarge) {
            try f.service.planOwnedPackage(source: .init(archiveData: bytes, directories: ["ProjectPhotos"], files: files),
                role: .validationMerged, packageID: id, accountIDHash: String(repeating: "a", count: 64),
                livePathSHA256: String(repeating: "b", count: 64), transactionID: id,
                appVersion: "1.2.0", now: Date(timeIntervalSince1970: 20),
                temporaryID: { _ in callbackCount += 1; return id })
        }
        #expect(callbackCount == 0)
    }

    @Test(arguments: [1, 2]) func expectedMarkupOwnerAndAncestorAliasesReject(component: Int) throws {
        let f = try BackupFixture.patternLibraryPackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        let owner = f.markupRelativePath.split(separator: "/").dropLast().map(String.init)
        let markupRoot = "Patterns/UsageMarkup"
        let directories = tree.directories.filter { $0 != markupRoot && !$0.hasPrefix(markupRoot + "/") }
        let files = tree.files.filter { !$0.key.hasPrefix(markupRoot + "/") }
        let absent = KnitNoteBackupFrozenTree(archiveData: tree.archiveData, directories: directories, files: files)
        let p = try plan(f, absent)
        var aliasedOwner = owner
        aliasedOwner[component] = aliasedOwner[component].lowercased()
        // A UUID could contain only digits; a diacritic still gives a deterministic owner alias.
        if component == 2 { aliasedOwner[component] += "\u{0301}" }
        #expect(!aliasedOwner[component].utf8.elementsEqual(owner[component].utf8))
        var aliasedDirectories = directories
        for count in 1...aliasedOwner.count { aliasedDirectories.insert(aliasedOwner.prefix(count).joined(separator: "/")) }
        var aliasedFiles = files
        aliasedFiles[aliasedOwner.joined(separator: "/") + "/0.json"] = tree.files[f.markupRelativePath]
        let aliased = KnitNoteBackupFrozenTree(archiveData: tree.archiveData, directories: aliasedDirectories, files: aliasedFiles)
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) { try plan(f, aliased) }
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) { try f.service.validateFrozenPackageSource(p, source: aliased) }
    }

    @Test func manifestAndAggregatePackageCapsReject() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try f.service.planOwnedPackage(source: tree, role: .validationMerged, packageID: id,
                accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
                transactionID: id, appVersion: String(repeating: "a", count: 1_000_001), now: Date(timeIntervalSince1970: 20))
        }
        var projects: [StoredProject] = []
        var files: [String: SyncBootstrapOutputProof] = [:]
        for _ in 0..<40 {
            var project = try StoredProject(name: "Photo")
            let name = project.id.uuidString + "-" + UUID().uuidString + ".jpg"
            project.setPhotoFilename(name)
            projects.append(project)
            files["ProjectPhotos/" + name] = .init(byteCount: 100_000_000, sha256: Data(repeating: 1, count: 32))
        }
        let bytes = try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: projects, yarns: []))
        files["projects-v1.json"] = .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
        #expect(throws: KnitNoteBackupError.packageTooLarge) {
            try plan(f, .init(archiveData: bytes, directories: ["ProjectPhotos"], files: files))
        }
    }

    @Test func unrelatedFilesAreNotDependenciesAndAbsentRootsNeedNoIO() throws {
        let bytes = try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: [], yarns: []))
        let tree = KnitNoteBackupFrozenTree(archiveData: bytes, directories: [], files: [
            "projects-v1.json": .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = KnitNoteBackupService(liveRoot: root.appendingPathComponent("Live"), workRoot: root.appendingPathComponent("Work"))
        let p = try service.planOwnedPackage(source: tree, role: .validationOriginal, packageID: id,
            accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
            transactionID: id, appVersion: "1.2.0", now: Date(timeIntervalSince1970: 20))
        var files = tree.files
        files["ignored.txt"] = .init(byteCount: 4, sha256: Data(repeating: 7, count: 32))
        try service.validateFrozenPackageSource(p, source: .init(archiveData: bytes, directories: [], files: files))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(p.sourceFiles.count == 1)
        #expect(p.output.reservations[.validationOriginal] != nil)
    }

    @Test func malformedProofAndTreeShapeAreRejected() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        for proof in [SyncBootstrapOutputProof(byteCount: -1, sha256: Data(repeating: 1, count: 32)),
                      SyncBootstrapOutputProof(byteCount: 1, sha256: Data(repeating: 1, count: 31))] {
            var files = tree.files; files[f.firstRelativePath] = proof
            #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
                try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
            }
        }
        for path in ["", "../bad", "bad//file", "bad\\file", "bad\u{0}file", "PROJECTS-V1.JSON"] {
            var files = tree.files; files[path] = .init(byteCount: 0, sha256: Data(repeating: 1, count: 32))
            #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
                try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
            }
        }
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories.union([f.firstRelativePath]), files: tree.files))
        }
    }

    @Test func archiveLimitPrecedesDecodeAndOwnedMediaLimitIsInclusive() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try plan(f, .init(archiveData: Data(repeating: 0, count: 20_000_001), directories: [], files: [:]))
        }
        #expect(throws: KnitNoteBackupError.invalidArchive) {
            try plan(f, .init(archiveData: Data(repeating: 0, count: 20_000_000), directories: [], files: [:]))
        }
        var files = tree.files
        files[f.firstRelativePath] = .init(byteCount: 100_000_000, sha256: Data(repeating: 1, count: 32))
        let result = try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        #expect(result.sourceFiles[f.firstRelativePath]?.byteCount == 100_000_000)
    }

    @Test func exactParentSpellingRejectsCanonicalUnicodeAlias() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        var directories = tree.directories; directories.insert("e\u{0301}")
        var files = tree.files
        files["é/ignored"] = .init(byteCount: 1, sha256: Data(repeating: 1, count: 32))
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            try plan(f, .init(archiveData: tree.archiveData, directories: directories, files: files))
        }
    }

    @Test func markupEntryAndByteCapsRemainSpecific() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        let owner = f.markupRelativePath.split(separator: "/").dropLast().joined(separator: "/")
        var files = tree.files.filter { !$0.key.hasPrefix(owner + "/") }
        for page in 0..<512 { files[owner + "/\(page).json"] = .init(byteCount: 2, sha256: Data(repeating: 1, count: 32)) }
        _ = try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        files[owner + "/512.json"] = .init(byteCount: 2, sha256: Data(repeating: 1, count: 32))
        #expect(throws: KnitNoteBackupError.invalidMarkup) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
        files = tree.files
        files[f.markupRelativePath] = .init(byteCount: 2_000_000, sha256: Data(repeating: 1, count: 32))
        _ = try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        files[f.markupRelativePath] = .init(byteCount: 2_000_001, sha256: Data(repeating: 1, count: 32))
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
    }

    @Test func archiveProofAndMissingReferenceReject() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        var files = tree.files
        let archive = try #require(files["projects-v1.json"])
        files["projects-v1.json"] = .init(byteCount: archive.byteCount, sha256: Data(repeating: 8, count: 32))
        #expect(throws: KnitNoteBackupError.integrityMismatch("projects-v1.json")) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
        files = tree.files; files.removeValue(forKey: f.firstRelativePath)
        #expect(throws: KnitNoteBackupError.missingReferencedFile(f.firstRelativePath)) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
    }

    @Test func roleTimestampAndEmptyArchiveAreExplicit() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            try f.service.planOwnedPackage(source: tree, role: .original, packageID: id,
                accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
                transactionID: id, appVersion: "1.2.0", now: Date(timeIntervalSince1970: 20))
        }
        let first = try plan(f, tree)
        let later = try f.service.planOwnedPackage(source: tree, role: .validationMerged, packageID: id,
            accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
            transactionID: id, appVersion: "1.2.0", now: Date(timeIntervalSince1970: 21))
        #expect(first.manifestData != later.manifestData)
        let bytes = try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: [], yarns: []))
        let empty = KnitNoteBackupFrozenTree(archiveData: bytes, directories: [], files: [
            "projects-v1.json": .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))])
        let result = try plan(f, empty)
        #expect(result.sourceFiles.count == 1)
        #expect(result.temporaryIDs.count == 2)
    }
}
