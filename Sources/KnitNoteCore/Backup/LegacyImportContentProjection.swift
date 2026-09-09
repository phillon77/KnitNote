import CryptoKit
import Foundation

struct LegacyImportContentEntry: Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let sha256: Data
}

enum LegacyImportContentProjection {
    static let maximumEncodedBytes = 1_000_000
    static let initialEncodedByteCount = Data("KnitNote.LegacyImportContent.v1\0".utf8).count
        + MemoryLayout<UInt64>.size

    static func digest(_ entries: [LegacyImportContentEntry]) throws -> Data {
        let entryCount = try preflight(entries)
        var aliases: Set<String> = []
        for entry in entries {
            try validate(entry)
            guard aliases.insert(alias(for: entry.relativePath)).inserted else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
        }
        guard entries.contains(where: {
            $0.relativePath.utf8.elementsEqual("projects-v1.json".utf8)
        }) else {
            throw KnitNoteBackupError.unsafePackageEntry
        }

        var encoded = Data()
        try append(Data("KnitNote.LegacyImportContent.v1\0".utf8), to: &encoded)
        try appendWord(entryCount, to: &encoded)
        for entry in entries.sorted(by: utf8LessThan) {
            let pathByteCount = entry.relativePath.utf8.count
            try appendWord(UInt64(pathByteCount), to: &encoded)
            try append(entry.relativePath.utf8, count: pathByteCount, to: &encoded)
            try appendWord(UInt64(entry.byteCount), to: &encoded)
            try append(entry.sha256, to: &encoded)
        }
        return Data(SHA256.hash(data: encoded))
    }

    private static func preflight(_ entries: [LegacyImportContentEntry]) throws -> UInt64 {
        guard let entryCount = UInt64(exactly: entries.count) else {
            throw KnitNoteBackupError.fileTooLarge
        }
        var encodedByteCount = 0
        func charge(_ byteCount: Int) throws {
            guard byteCount >= 0,
                  encodedByteCount <= maximumEncodedBytes,
                  byteCount <= maximumEncodedBytes - encodedByteCount else {
                throw KnitNoteBackupError.fileTooLarge
            }
            encodedByteCount += byteCount
        }

        try charge("KnitNote.LegacyImportContent.v1\0".utf8.count)
        try charge(MemoryLayout<UInt64>.size)
        for entry in entries {
            try charge(MemoryLayout<UInt64>.size)
            try charge(entry.relativePath.utf8.count)
            try charge(MemoryLayout<UInt64>.size)
            try charge(32)
        }
        return entryCount
    }

    static func projectedEntryByteCount(forRelativePath relativePath: String) throws -> Int {
        try validate(relativePath: relativePath)
        let fixedBytes = 2 * MemoryLayout<UInt64>.size + 32
        let (total, overflow) = fixedBytes.addingReportingOverflow(relativePath.utf8.count)
        guard !overflow else { throw KnitNoteBackupError.fileTooLarge }
        return total
    }

    private static func validate(_ entry: LegacyImportContentEntry) throws {
        try validate(relativePath: entry.relativePath)
        guard entry.byteCount >= 0,
              entry.sha256.count == 32 else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
    }

    private static func validate(relativePath: String) throws {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && !component.contains("\\")
                      && !component.utf8.contains(0)
              }) else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
    }

    static func alias(for path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func utf8LessThan(
        _ left: LegacyImportContentEntry,
        _ right: LegacyImportContentEntry
    ) -> Bool {
        left.relativePath.utf8.lexicographicallyPrecedes(right.relativePath.utf8)
    }

    private static func appendWord(_ value: UInt64, to data: inout Data) throws {
        try requireBudget(MemoryLayout<UInt64>.size, in: data)
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func append(_ bytes: Data, to data: inout Data) throws {
        try requireBudget(bytes.count, in: data)
        data.append(bytes)
    }

    private static func append<Bytes: Sequence>(
        _ bytes: Bytes,
        count: Int,
        to data: inout Data
    ) throws where Bytes.Element == UInt8 {
        try requireBudget(count, in: data)
        data.append(contentsOf: bytes)
    }

    private static func requireBudget(_ byteCount: Int, in data: Data) throws {
        guard byteCount >= 0,
              data.count <= maximumEncodedBytes,
              byteCount <= maximumEncodedBytes - data.count else {
            throw KnitNoteBackupError.fileTooLarge
        }
    }
}
