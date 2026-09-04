import CloudKit
import Foundation

enum CloudRecordCodecError: Error, Equatable {
    case malformedRecord
    case unsupportedRecordType(String)
    case recordIdentityMismatch
    case payloadTooLarge
}

struct CloudRecordCodec {
    static let maximumNonAssetPayloadByteCount = 256 * 1024

    func encode(_ record: SyncRecord, zoneID: CKRecordZone.ID) throws -> CKRecord {
        let validated = try SyncRecordValidator().validate(record)
        let relationships = Self.wireRelationships(validated.relationships)
        let fields = try Self.encodeJSON(validated.payload.fields)
        let deletedStamp = try Self.encodeJSON(validated.deletedAt.stamp)
        let deletionCascade = try validated.payload.deletionCascade.map(Self.encodeJSON)
        let atomicDomain = try validated.payload.atomicDomain.map(Self.encodeJSON)
        let attachment = try validated.payload.attachment.map(Self.encodeJSON)
        let wirePayload = WirePayload(
            recordType: Self.recordType(for: validated.id.kind),
            recordName: Self.recordName(for: validated.id),
            schemaVersion: validated.schemaVersion,
            entityID: validated.id.uuid.uuidString.lowercased(),
            createdAt: validated.createdAt,
            entityRevision: String(validated.entityRevision),
            deletedAt: validated.deletedAt.value,
            deletedStamp: deletedStamp,
            fields: fields,
            deletionCascade: deletionCascade,
            atomicDomain: atomicDomain,
            attachment: attachment,
            relationships: relationships
        )
        try Self.validatePayloadSize(wirePayload)

        let recordID = CKRecord.ID(recordName: wirePayload.recordName, zoneID: zoneID)
        let cloudRecord = CKRecord(recordType: wirePayload.recordType, recordID: recordID)
        cloudRecord[Field.schemaVersion] = wirePayload.schemaVersion as NSNumber
        cloudRecord[Field.entityID] = wirePayload.entityID as NSString
        cloudRecord[Field.createdAt] = wirePayload.createdAt as NSDate
        cloudRecord[Field.entityRevision] = wirePayload.entityRevision as NSString
        if let deletedAt = wirePayload.deletedAt {
            cloudRecord[Field.deletedAt] = deletedAt as NSDate
        }
        cloudRecord[Field.deletedStamp] = wirePayload.deletedStamp as NSData
        cloudRecord[Field.fields] = wirePayload.fields as NSData
        if let deletionCascade = wirePayload.deletionCascade {
            cloudRecord[Field.deletionCascade] = deletionCascade as NSData
        }
        if let atomicDomain = wirePayload.atomicDomain {
            cloudRecord[Field.atomicDomain] = atomicDomain as NSData
        }
        if let attachment = wirePayload.attachment {
            cloudRecord[Field.attachment] = attachment as NSData
        }
        if !relationships.isEmpty {
            cloudRecord[Field.relationshipRoles] = relationships.map(\.role) as NSArray
            cloudRecord[Field.relationshipKinds] = relationships.map(\.kind) as NSArray
            cloudRecord[Field.relationshipUUIDs] = relationships.map(\.uuid) as NSArray
        }
        return cloudRecord
    }

    func decode(_ record: CKRecord) throws -> SyncRecord {
        try Self.validateIncomingNonAssetPayloadSize(record)
        let kind = try Self.kind(forRecordType: record.recordType)
        let schemaVersion = try Self.requiredInt(record, field: Field.schemaVersion)
        let entityID = try Self.requiredUUID(record, field: Field.entityID)
        let expectedID = SyncEntityID(kind: kind, uuid: entityID)
        guard record.recordID.recordName == Self.recordName(for: expectedID) else {
            throw CloudRecordCodecError.recordIdentityMismatch
        }
        let relationships = try Self.decodeRelationships(from: record)
        let wirePayload = WirePayload(
            recordType: record.recordType,
            recordName: record.recordID.recordName,
            schemaVersion: schemaVersion,
            entityID: entityID.uuidString.lowercased(),
            createdAt: try Self.requiredDate(record, field: Field.createdAt),
            entityRevision: try Self.requiredString(record, field: Field.entityRevision),
            deletedAt: try Self.optionalDate(record, field: Field.deletedAt),
            deletedStamp: try Self.requiredData(record, field: Field.deletedStamp),
            fields: try Self.requiredData(record, field: Field.fields),
            deletionCascade: try Self.optionalData(record, field: Field.deletionCascade),
            atomicDomain: try Self.optionalData(record, field: Field.atomicDomain),
            attachment: try Self.optionalData(record, field: Field.attachment),
            relationships: relationships
        )
        try Self.validatePayloadSize(wirePayload)

        guard let entityRevision = UInt64(wirePayload.entityRevision) else {
            throw CloudRecordCodecError.malformedRecord
        }
        let decoded = SyncRecord(
            schemaVersion: wirePayload.schemaVersion,
            id: expectedID,
            createdAt: wirePayload.createdAt,
            entityRevision: entityRevision,
            payload: .init(
                fields: try Self.decodeJSON(
                    [String: SyncFieldVersion<SyncScalar>].self,
                    from: wirePayload.fields
                ),
                deletionCascade: try wirePayload.deletionCascade.map {
                    try Self.decodeJSON(SyncFieldVersion<[SyncEntityID]>.self, from: $0)
                },
                atomicDomain: try wirePayload.atomicDomain.map {
                    try Self.decodeJSON(SyncFieldVersion<SyncAtomicDomainValue>.self, from: $0)
                },
                attachment: try wirePayload.attachment.map {
                    try Self.decodeJSON(SyncAttachmentVersion.self, from: $0)
                }
            ),
            relationships: relationships.map {
                SyncRelationship(
                    role: $0.role,
                    target: .init(kind: $0.entityKind, uuid: $0.entityID)
                )
            },
            deletedAt: .init(
                value: wirePayload.deletedAt,
                stamp: try Self.decodeJSON(SyncMutationStamp.self, from: wirePayload.deletedStamp)
            )
        )
        return try SyncRecordValidator().validate(decoded)
    }

    static func recordType(for kind: SyncEntityKind) -> String {
        kind.rawValue
    }

    private static func kind(forRecordType recordType: String) throws -> SyncEntityKind {
        guard let kind = SyncEntityKind(rawValue: recordType) else {
            throw CloudRecordCodecError.unsupportedRecordType(recordType)
        }
        return kind
    }

    private static func recordName(for id: SyncEntityID) -> String {
        "\(id.kind.rawValue)-\(id.uuid.uuidString.lowercased())"
    }

    private static func wireRelationships(_ relationships: [SyncRelationship]) -> [WireRelationship] {
        relationships.map {
            WireRelationship(role: $0.role, kind: $0.target.kind.rawValue, uuid: $0.target.uuid.uuidString.lowercased())
        }
    }

    private static func decodeRelationships(from record: CKRecord) throws -> [WireRelationship] {
        let roles = record[Field.relationshipRoles]
        let kinds = record[Field.relationshipKinds]
        let uuids = record[Field.relationshipUUIDs]
        guard roles != nil || kinds != nil || uuids != nil else { return [] }
        guard let roles = roles as? [String],
              let kinds = kinds as? [String],
              let uuids = uuids as? [String],
              roles.count == kinds.count,
              kinds.count == uuids.count else {
            throw CloudRecordCodecError.malformedRecord
        }
        let relationships = zip(zip(roles, kinds), uuids).map { pair in
            WireRelationship(role: pair.0.0, kind: pair.0.1, uuid: pair.1)
        }
        guard relationships.allSatisfy({
            SyncEntityKind(rawValue: $0.kind) != nil && UUID(uuidString: $0.uuid) != nil
        }) else {
            throw CloudRecordCodecError.malformedRecord
        }
        return relationships
    }

    private static func validatePayloadSize(_ payload: WirePayload) throws {
        guard try encodeJSON(payload).count <= maximumNonAssetPayloadByteCount else {
            throw CloudRecordCodecError.payloadTooLarge
        }
    }

    private static func validateIncomingNonAssetPayloadSize(_ record: CKRecord) throws {
        let fields = record.allKeys().sorted().compactMap { key -> [Any]? in
            guard let value = record[key], !(value is CKAsset) else { return nil }
            return [key, value]
        }
        do {
            let payload = try NSKeyedArchiver.archivedData(
                withRootObject: fields,
                requiringSecureCoding: true
            )
            guard payload.count <= maximumNonAssetPayloadByteCount else {
                throw CloudRecordCodecError.payloadTooLarge
            }
        } catch let error as CloudRecordCodecError {
            throw error
        } catch {
            throw CloudRecordCodecError.malformedRecord
        }
    }

    private static func encodeJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decodeJSON<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }

    private static func requiredString(_ record: CKRecord, field: String) throws -> String {
        guard let value = record[field] as? String else { throw CloudRecordCodecError.malformedRecord }
        return value
    }

    private static func requiredInt(_ record: CKRecord, field: String) throws -> Int {
        guard let value = record[field] as? NSNumber else { throw CloudRecordCodecError.malformedRecord }
        let integer = value.intValue
        guard value.doubleValue.isFinite, value.doubleValue == Double(integer) else {
            throw CloudRecordCodecError.malformedRecord
        }
        return integer
    }

    private static func requiredDate(_ record: CKRecord, field: String) throws -> Date {
        guard let value = record[field] as? Date else { throw CloudRecordCodecError.malformedRecord }
        return value
    }

    private static func requiredUUID(_ record: CKRecord, field: String) throws -> UUID {
        guard let value = UUID(uuidString: try requiredString(record, field: field)) else {
            throw CloudRecordCodecError.malformedRecord
        }
        return value
    }

    private static func requiredData(_ record: CKRecord, field: String) throws -> Data {
        guard let value = record[field] as? Data else { throw CloudRecordCodecError.malformedRecord }
        return value
    }

    private static func optionalDate(_ record: CKRecord, field: String) throws -> Date? {
        guard let value = record[field] else { return nil }
        guard let date = value as? Date else { throw CloudRecordCodecError.malformedRecord }
        return date
    }

    private static func optionalData(_ record: CKRecord, field: String) throws -> Data? {
        guard let value = record[field] else { return nil }
        guard let data = value as? Data else { throw CloudRecordCodecError.malformedRecord }
        return data
    }
}

private extension CloudRecordCodec {
    enum Field {
        static let schemaVersion = "schemaVersion"
        static let entityID = "entityID"
        static let createdAt = "createdAt"
        static let entityRevision = "entityRevision"
        static let deletedAt = "deletedAt"
        static let deletedStamp = "deletedStamp"
        static let fields = "fields"
        static let deletionCascade = "deletionCascade"
        static let atomicDomain = "atomicDomain"
        static let attachment = "attachment"
        static let relationshipRoles = "relationshipRoles"
        static let relationshipKinds = "relationshipKinds"
        static let relationshipUUIDs = "relationshipUUIDs"
    }

    struct WireRelationship: Codable, Equatable {
        let role: String
        let kind: String
        let uuid: String

        var entityKind: SyncEntityKind { SyncEntityKind(rawValue: kind)! }
        var entityID: UUID { UUID(uuidString: uuid)! }
    }

    struct WirePayload: Codable {
        let recordType: String
        let recordName: String
        let schemaVersion: Int
        let entityID: String
        let createdAt: Date
        let entityRevision: String
        let deletedAt: Date?
        let deletedStamp: Data
        let fields: Data
        let deletionCascade: Data?
        let atomicDomain: Data?
        let attachment: Data?
        let relationships: [WireRelationship]
    }
}
