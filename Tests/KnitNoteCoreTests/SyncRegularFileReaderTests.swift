import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncRegularFileReaderTests {
    @Test(.timeLimit(.minutes(1))) func fifoFailsWithoutBlocking() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let fifo = fixture.url(named: "input.fifo")
        #expect(fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        #expect(throws: SyncRegularFileReadError.unsafeFile) {
            _ = try SyncRegularFileReader().read(fifo, maximumBytes: 1_024)
        }
    }

    @Test func symlinkIsRejectedWithoutFollowingTarget() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let target = fixture.url(named: "target.json")
        let link = fixture.url(named: "link.json")
        let bytes = Data("private target".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: SyncRegularFileReadError.unsafeFile) {
            _ = try SyncRegularFileReader().read(link, maximumBytes: 1_024)
        }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func unixSocketIsRejectedWithoutOpeningIt() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let socket = try fixture.makeSocket(named: "sync.sock")

        #expect(throws: SyncRegularFileReadError.unsafeFile) {
            _ = try SyncRegularFileReader().read(socket, maximumBytes: 1_024)
        }
    }

    @Test func descriptorIdentityRejectsPathReplacement() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "replace.json")
        try Data("first".utf8).write(to: file)
        let reader = SyncRegularFileReader(beforeOpen: {
            try FileManager.default.removeItem(at: file)
            try Data("second".utf8).write(to: file)
        })

        #expect(throws: SyncRegularFileReadError.replaced) {
            _ = try reader.read(file, maximumBytes: 1_024)
        }
    }

    @Test func oversizedDeclaredSizeIsRejectedBeforePayloadRead() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "oversized.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_025)
        try handle.close()

        #expect(throws: SyncRegularFileReadError.tooLarge) {
            _ = try SyncRegularFileReader().read(file, maximumBytes: 1_024)
        }
    }

    @Test func declaredSizeMismatchIsRejectedBeforeAllocationOrPayloadRead() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "declared-size-mismatch.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_000_000)
        try handle.close()
        let counters = SyncRegularFileReaderIOCounters()

        #expect(throws: SyncRegularFileReadError.expectationMismatch) {
            _ = try SyncRegularFileReader(ioCounters: counters).read(
                file,
                maximumBytes: 2_000_000,
                expected: .init(byteCount: 4)
            )
        }
        #expect(counters.bytesRead == 0)
    }

    @Test func growthAfterFstatConsumesOnlyOneOverrunByteBeyondDeclaredSize() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "declared-size-growth.bin")
        try Data("safe".utf8).write(to: file)
        let counters = SyncRegularFileReaderIOCounters()
        let reader = SyncRegularFileReader(
            beforeRead: {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x41, count: 1_000_000))
                try handle.close()
            },
            ioCounters: counters
        )

        #expect(throws: SyncRegularFileReadError.expectationMismatch) {
            _ = try reader.read(
                file,
                maximumBytes: 2_000_000,
                expected: .init(byteCount: 4)
            )
        }
        #expect(counters.bytesRead == 5)
    }

    @Test func boundedObservationAtMaximumRetainsOnlyDeclaredBytesAndOneProbe() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "observation-at-cap.bin")
        let declared = Data("safe".utf8)
        try (declared + Data([0x41])).write(to: file)
        let counters = SyncRegularFileReaderIOCounters()

        let observation = try SyncRegularFileReader(ioCounters: counters).observe(
            file,
            declaredByteCount: Int64(declared.count),
            maximumBytes: declared.count + 1
        )

        #expect(observation.hasSizeMismatch)
        #expect(observation.data == declared)
        #expect(observation.sha256 == Data(SHA256.hash(data: declared)))
        #expect(counters.bytesRead == declared.count + 1)
    }

    @Test func observationRejectsAnyBudgetOtherThanDeclaredPlusOne() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "observation-wrong-budget.bin")
        try Data("safe".utf8).write(to: file)

        #expect(throws: SyncRegularFileReadError.tooLarge) {
            _ = try SyncRegularFileReader().observe(
                file,
                declaredByteCount: 4,
                maximumBytes: 100_000_000
            )
        }
    }

    @Test func integerMaximumCapDoesNotOverflowTheOverrunProbe() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "empty-at-integer-cap.bin")
        try Data().write(to: file)

        let read = try SyncRegularFileReader().read(file, maximumBytes: Int.max)

        #expect(read.data.isEmpty)
        #expect(read.byteCount == 0)
    }

    @Test func growthBeyondCapIsRejectedDuringRead() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "growing.bin")
        try Data(repeating: 0x41, count: 1_024).write(to: file)
        let reader = SyncRegularFileReader(beforeRead: {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x42]))
            try handle.close()
        })

        #expect(throws: SyncRegularFileReadError.tooLarge) {
            _ = try reader.read(file, maximumBytes: 1_024)
        }
    }

    @Test func regularFileReturnsDescriptorEvidenceWhenExpectedBytesAndHashMatch() throws {
        let fixture = try SyncRegularFileReaderFixture()
        let file = fixture.url(named: "regular.json")
        let bytes = Data("immutable bytes".utf8)
        try bytes.write(to: file)
        let expectedHash = Data(SHA256.hash(data: bytes))

        let read = try SyncRegularFileReader().read(
            file,
            maximumBytes: 1_024,
            expected: .init(byteCount: Int64(bytes.count), sha256: expectedHash)
        )

        #expect(read.data == bytes)
        #expect(read.byteCount == Int64(bytes.count))
        #expect(read.sha256 == expectedHash)
        #expect(read.device > 0)
        #expect(read.inode > 0)
    }
}

private final class SyncRegularFileReaderFixture {
    let directory: URL
    private var sockets: [URL] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-regular-file-reader-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        for socket in sockets { try? FileManager.default.removeItem(at: socket) }
        try? FileManager.default.removeItem(at: directory)
    }

    func url(named name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    func makeSocket(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/knitnote-\(UUID().uuidString.prefix(8)).\(name)")
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        let pathOffset = try #require(MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path))
        try #require(path.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address) { addressBytes in
            addressBytes.baseAddress!.advanced(by: pathOffset).copyMemory(
                from: path,
                byteCount: path.count
            )
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        sockets.append(url)
        return url
    }
}
