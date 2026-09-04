import CloudKit
import Foundation

enum CloudRecordSystemFieldsStoreError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
    case wrongZone
}

struct FileCloudRecordSystemFieldsStore: @unchecked Sendable {
    private let file: DescriptorRelativeAtomicFile
    private let zoneID: CKRecordZone.ID

    init(url: URL, zoneID: CKRecordZone.ID) {
        file = DescriptorRelativeAtomicFile(url: url)
        self.zoneID = zoneID
    }

    func load(recordID: CKRecord.ID, accountIdentifier: String) throws -> CKRecord? {
        guard recordID.zoneID == zoneID else { throw CloudRecordSystemFieldsStoreError.wrongZone }
        let envelope = try loadEnvelope()
        guard let data = envelope.accounts[accountIdentifier]?[recordID.recordName] else {
            return nil
        }
        return try Self.decodeRecord(data, expectedID: recordID)
    }

    func loadUnique(recordID: CKRecord.ID) throws -> CKRecord? {
        guard recordID.zoneID == zoneID else { throw CloudRecordSystemFieldsStoreError.wrongZone }
        let matches = try loadEnvelope().accounts.values.compactMap { $0[recordID.recordName] }
        guard matches.count <= 1 else { throw CloudRecordSystemFieldsStoreError.corrupt }
        return try matches.first.map { try Self.decodeRecord($0, expectedID: recordID) }
    }

    func save(_ record: CKRecord, accountIdentifier: String) throws {
        guard record.recordID.zoneID == zoneID else {
            throw CloudRecordSystemFieldsStoreError.wrongZone
        }
        var envelope = try loadEnvelope()
        var account = envelope.accounts[accountIdentifier, default: [:]]
        account[record.recordID.recordName] = try Self.encodeSystemFields(record)
        envelope.accounts[accountIdentifier] = account
        try saveEnvelope(envelope)
    }

    func remove(recordID: CKRecord.ID, accountIdentifier: String) throws {
        guard recordID.zoneID == zoneID else { throw CloudRecordSystemFieldsStoreError.wrongZone }
        var envelope = try loadEnvelope()
        envelope.accounts[accountIdentifier]?.removeValue(forKey: recordID.recordName)
        try saveEnvelope(envelope)
    }

    private func loadEnvelope() throws -> SystemFieldsEnvelope {
        do {
            guard let data = try file.read() else {
                return SystemFieldsEnvelope(
                    version: 1,
                    zoneName: zoneID.zoneName,
                    ownerName: zoneID.ownerName,
                    accounts: [:]
                )
            }
            let envelope = try JSONDecoder().decode(SystemFieldsEnvelope.self, from: data)
            guard envelope.version == 1,
                  envelope.zoneName == zoneID.zoneName,
                  envelope.ownerName == zoneID.ownerName else {
                throw CloudRecordSystemFieldsStoreError.corrupt
            }
            return envelope
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch let error as CloudRecordSystemFieldsStoreError {
            throw error
        } catch {
            throw CloudRecordSystemFieldsStoreError.corrupt
        }
    }

    private func saveEnvelope(_ envelope: SystemFieldsEnvelope) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try file.write(encoder.encode(envelope))
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch is EncodingError {
            throw CloudRecordSystemFieldsStoreError.corrupt
        }
    }

    private static func encodeSystemFields(_ record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func decodeRecord(_ data: Data, expectedID: CKRecord.ID) throws -> CKRecord {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            guard let record = CKRecord(coder: unarchiver), record.recordID == expectedID else {
                throw CloudRecordSystemFieldsStoreError.corrupt
            }
            return record
        } catch let error as CloudRecordSystemFieldsStoreError {
            throw error
        } catch {
            throw CloudRecordSystemFieldsStoreError.corrupt
        }
    }

    private static func map(
        _ error: DescriptorRelativeAtomicFileError
    ) -> CloudRecordSystemFieldsStoreError {
        switch error {
        case .corrupt: .corrupt
        case .unsafeFile: .unsafeFile
        case .unavailable: .unavailable
        }
    }
}

private struct SystemFieldsEnvelope: Codable {
    let version: Int
    let zoneName: String
    let ownerName: String
    var accounts: [String: [String: Data]]
}
