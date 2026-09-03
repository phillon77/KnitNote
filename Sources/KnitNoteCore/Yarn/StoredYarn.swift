import Foundation

public enum YarnValidationError: Error, Equatable, Sendable {
    case emptyName
    case negativeInventory
    case invalidMetricRange
    case negativeLabelMeasurement
    case invalidLabelPhotoFilenames
}

public struct YarnMetricRange: Codable, Equatable, Sendable {
    public let lower: Decimal
    public let upper: Decimal

    private enum CodingKeys: String, CodingKey {
        case lower
        case upper
    }

    public init(lower: Decimal, upper: Decimal) throws {
        guard lower.isFinite, upper.isFinite, lower >= 0, upper >= lower else {
            throw YarnValidationError.invalidMetricRange
        }
        self.lower = lower
        self.upper = upper
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let lower = try values.decode(Decimal.self, forKey: .lower)
        let upper = try values.decode(Decimal.self, forKey: .upper)
        do {
            try self.init(lower: lower, upper: upper)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .upper,
                in: values,
                debugDescription: "A yarn metric range must be finite, nonnegative, and ascending."
            )
        }
    }
}

public enum YarnDecimalInput: Equatable, Sendable {
    case empty
    case value(Decimal)
    case invalid
    case negative

    public var value: Decimal? {
        guard case let .value(value) = self else { return nil }
        return value
    }

    public var isValid: Bool {
        switch self {
        case .empty, .value:
            true
        case .invalid, .negative:
            false
        }
    }
}

public struct YarnInventoryEditValue: Equatable, Sendable {
    public var text: String
    private let originalText: String
    private let originalValue: Decimal?

    public init() {
        text = ""
        originalText = ""
        originalValue = nil
    }

    public init(value: Decimal?, locale: Locale) {
        let text = Self.string(from: value, locale: locale)
        self.text = text
        originalText = text
        originalValue = value
    }

    public func input(locale: Locale) -> YarnDecimalInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        formatter.isLenient = false
        let fullRange = NSRange(location: 0, length: (trimmed as NSString).length)
        var parsedRange = fullRange
        var parsed: AnyObject?
        do {
            try formatter.getObjectValue(&parsed, for: trimmed, range: &parsedRange)
        } catch {
            return .invalid
        }
        guard parsedRange == fullRange, parsed != nil else {
            return .invalid
        }
        var exactText = trimmed
        if let groupingSeparator = formatter.groupingSeparator, !groupingSeparator.isEmpty {
            exactText = exactText.replacingOccurrences(of: groupingSeparator, with: "")
        }
        guard let value = Decimal(string: exactText, locale: locale), value.isFinite else {
            return .invalid
        }
        guard value >= 0 else { return .negative }
        return .value(value)
    }

    public func resolvedValue(locale: Locale) -> Decimal? {
        if text == originalText {
            return originalValue
        }
        return input(locale: locale).value
    }

    private static func string(from value: Decimal?, locale: Locale) -> String {
        guard let value else { return "" }
        var decimal = value
        return NSDecimalString(&decimal, locale as NSLocale)
    }
}

public struct StoredYarn: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public private(set) var name: String
    public private(set) var photoFilename: String?
    public private(set) var brand: String?
    public private(set) var series: String?
    public private(set) var color: String?
    public private(set) var colorCode: String?
    public private(set) var dyeLot: String?
    public private(set) var ballWeightGrams: Decimal?
    public private(set) var lengthMeters: Decimal?
    public private(set) var fiberContent: String?
    public private(set) var recommendedNeedleMM: YarnMetricRange?
    public private(set) var recommendedHookMM: YarnMetricRange?
    public private(set) var labelPhotoFilenames: [String]
    /// Stable semantic identities paired by index with `labelPhotoFilenames`.
    /// Unlike array positions, these survive removal of an earlier label.
    public private(set) var labelPhotoSlotIDs: [UUID]
    public private(set) var remainingBalls: Decimal?
    public private(set) var remainingGrams: Decimal?
    public private(set) var storageLocation: String?
    public private(set) var notes: String?
    public private(set) var linkedProjectIDs: Set<UUID>
    public let createdAt: Date
    public private(set) var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case photoFilename
        case brand
        case series
        case color
        case colorCode
        case dyeLot
        case ballWeightGrams
        case lengthMeters
        case fiberContent
        case recommendedNeedleMM
        case recommendedHookMM
        case labelPhotoFilenames
        case labelPhotoSlotIDs
        case remainingBalls
        case remainingGrams
        case storageLocation
        case notes
        case linkedProjectIDs
        case createdAt
        case updatedAt
    }

    public init(id: UUID = UUID(), name: String, now: Date = .now) throws {
        let name = Self.normalized(name)
        guard let name else { throw YarnValidationError.emptyName }

        self.id = id
        self.name = name
        photoFilename = nil
        brand = nil
        series = nil
        color = nil
        colorCode = nil
        dyeLot = nil
        ballWeightGrams = nil
        lengthMeters = nil
        fiberContent = nil
        recommendedNeedleMM = nil
        recommendedHookMM = nil
        labelPhotoFilenames = []
        labelPhotoSlotIDs = []
        remainingBalls = nil
        remainingGrams = nil
        storageLocation = nil
        notes = nil
        linkedProjectIDs = []
        createdAt = now
        updatedAt = now
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)

        let decodedName = Self.normalized(try values.decode(String.self, forKey: .name))
        guard let decodedName else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: values,
                debugDescription: "A yarn name must contain non-whitespace characters."
            )
        }
        name = decodedName
        photoFilename = Self.normalized(try values.decodeIfPresent(String.self, forKey: .photoFilename))
        brand = Self.normalized(try values.decodeIfPresent(String.self, forKey: .brand))
        series = Self.normalized(try values.decodeIfPresent(String.self, forKey: .series))
        color = Self.normalized(try values.decodeIfPresent(String.self, forKey: .color))
        colorCode = Self.normalized(try values.decodeIfPresent(String.self, forKey: .colorCode))
        dyeLot = Self.normalized(try values.decodeIfPresent(String.self, forKey: .dyeLot))
        ballWeightGrams = try values.decodeIfPresent(Decimal.self, forKey: .ballWeightGrams)
        lengthMeters = try values.decodeIfPresent(Decimal.self, forKey: .lengthMeters)
        fiberContent = Self.normalized(try values.decodeIfPresent(String.self, forKey: .fiberContent))
        recommendedNeedleMM = try values.decodeIfPresent(
            YarnMetricRange.self,
            forKey: .recommendedNeedleMM
        )
        recommendedHookMM = try values.decodeIfPresent(
            YarnMetricRange.self,
            forKey: .recommendedHookMM
        )
        labelPhotoFilenames = try values.decodeIfPresent(
            [String].self,
            forKey: .labelPhotoFilenames
        ) ?? []
        labelPhotoSlotIDs = try values.decodeIfPresent(
            [UUID].self,
            forKey: .labelPhotoSlotIDs
        ) ?? labelPhotoFilenames.compactMap(Self.legacyLabelPhotoSlotID)
        remainingBalls = try values.decodeIfPresent(Decimal.self, forKey: .remainingBalls)
        remainingGrams = try values.decodeIfPresent(Decimal.self, forKey: .remainingGrams)

        if remainingBalls.map({ $0 < 0 }) == true {
            throw DecodingError.dataCorruptedError(
                forKey: .remainingBalls,
                in: values,
                debugDescription: "Yarn inventory cannot be negative."
            )
        }
        if remainingGrams.map({ $0 < 0 }) == true {
            throw DecodingError.dataCorruptedError(
                forKey: .remainingGrams,
                in: values,
                debugDescription: "Yarn inventory cannot be negative."
            )
        }
        if ballWeightGrams.map({ !$0.isFinite || $0 < 0 }) == true {
            throw DecodingError.dataCorruptedError(
                forKey: .ballWeightGrams,
                in: values,
                debugDescription: "A yarn label weight must be finite and nonnegative."
            )
        }
        if lengthMeters.map({ !$0.isFinite || $0 < 0 }) == true {
            throw DecodingError.dataCorruptedError(
                forKey: .lengthMeters,
                in: values,
                debugDescription: "A yarn label length must be finite and nonnegative."
            )
        }
        guard Self.areValidLabelPhotoFilenames(labelPhotoFilenames, yarnID: id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .labelPhotoFilenames,
                in: values,
                debugDescription: "Yarn label photos must be managed files owned by this yarn."
            )
        }
        guard labelPhotoSlotIDs.count == labelPhotoFilenames.count,
              Set(labelPhotoSlotIDs).count == labelPhotoSlotIDs.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .labelPhotoSlotIDs,
                in: values,
                debugDescription: "Yarn label photo slot identities must be complete and unique."
            )
        }

        storageLocation = Self.normalized(
            try values.decodeIfPresent(String.self, forKey: .storageLocation)
        )
        notes = Self.normalized(try values.decodeIfPresent(String.self, forKey: .notes))
        linkedProjectIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .linkedProjectIDs) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public mutating func rename(to value: String, now: Date = .now) throws {
        let value = Self.normalized(value)
        guard let value else { throw YarnValidationError.emptyName }
        guard name != value else { return }
        name = value
        updatedAt = now
    }

    public mutating func updateInventory(
        balls: Decimal?,
        grams: Decimal?,
        now: Date = .now
    ) throws {
        guard balls.map({ $0 < 0 }) != true, grams.map({ $0 < 0 }) != true else {
            throw YarnValidationError.negativeInventory
        }
        guard remainingBalls != balls || remainingGrams != grams else { return }
        remainingBalls = balls
        remainingGrams = grams
        updatedAt = now
    }

    public mutating func updateDetails(
        brand: String?,
        series: String?,
        color: String?,
        colorCode: String?,
        dyeLot: String?,
        storageLocation: String?,
        notes: String?,
        now: Date = .now
    ) throws {
        let brand = Self.normalized(brand)
        let series = Self.normalized(series)
        let color = Self.normalized(color)
        let colorCode = Self.normalized(colorCode)
        let dyeLot = Self.normalized(dyeLot)
        let storageLocation = Self.normalized(storageLocation)
        let notes = Self.normalized(notes)
        guard self.brand != brand || self.series != series || self.color != color ||
                self.colorCode != colorCode || self.dyeLot != dyeLot ||
                self.storageLocation != storageLocation || self.notes != notes else {
            return
        }
        self.brand = brand
        self.series = series
        self.color = color
        self.colorCode = colorCode
        self.dyeLot = dyeLot
        self.storageLocation = storageLocation
        self.notes = notes
        updatedAt = now
    }

    public mutating func updateLabelDetails(
        ballWeightGrams: Decimal?,
        lengthMeters: Decimal?,
        fiberContent: String?,
        recommendedNeedleMM: YarnMetricRange?,
        recommendedHookMM: YarnMetricRange?,
        now: Date = .now
    ) throws {
        guard ballWeightGrams.map({ $0.isFinite && $0 >= 0 }) != false,
              lengthMeters.map({ $0.isFinite && $0 >= 0 }) != false else {
            throw YarnValidationError.negativeLabelMeasurement
        }
        let fiberContent = Self.normalized(fiberContent)
        guard self.ballWeightGrams != ballWeightGrams || self.lengthMeters != lengthMeters ||
                self.fiberContent != fiberContent ||
                self.recommendedNeedleMM != recommendedNeedleMM ||
                self.recommendedHookMM != recommendedHookMM else {
            return
        }
        self.ballWeightGrams = ballWeightGrams
        self.lengthMeters = lengthMeters
        self.fiberContent = fiberContent
        self.recommendedNeedleMM = recommendedNeedleMM
        self.recommendedHookMM = recommendedHookMM
        updatedAt = now
    }

    mutating func setLabelPhotoFilenames(_ filenames: [String], now: Date = .now) throws {
        guard Self.areValidLabelPhotoFilenames(filenames, yarnID: id) else {
            throw YarnValidationError.invalidLabelPhotoFilenames
        }
        guard labelPhotoFilenames != filenames else { return }
        let existingByFilename = Dictionary(
            uniqueKeysWithValues: zip(labelPhotoFilenames, labelPhotoSlotIDs).map { ($0, $1) }
        )
        let existingByOrdinal: [Character: UUID] = Dictionary(
            uniqueKeysWithValues: zip(labelPhotoFilenames, labelPhotoSlotIDs).compactMap {
                guard let ordinal = Self.labelPhotoOrdinal($0.0) else { return nil }
                return (ordinal, $0.1)
            }
        )
        var used: Set<UUID> = []
        labelPhotoSlotIDs = filenames.map { filename in
            let candidate = existingByFilename[filename]
                ?? Self.labelPhotoOrdinal(filename).flatMap { existingByOrdinal[$0] }
                ?? Self.legacyLabelPhotoSlotID(filename)
                ?? UUID()
            if used.insert(candidate).inserted { return candidate }
            let fresh = UUID()
            used.insert(fresh)
            return fresh
        }
        labelPhotoFilenames = filenames
        updatedAt = now
    }

    public mutating func setPhotoFilename(_ filename: String?, now: Date = .now) {
        let filename = Self.normalized(filename)
        guard photoFilename != filename else { return }
        photoFilename = filename
        updatedAt = now
    }

    public mutating func setLinkedProjectIDs(_ projectIDs: Set<UUID>, now: Date = .now) {
        guard linkedProjectIDs != projectIDs else { return }
        linkedProjectIDs = projectIDs
        updatedAt = now
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isManagedLabelPhotoFilename(_ filename: String, yarnID: UUID) -> Bool {
        guard filename.hasSuffix(".jpg") else { return false }
        let stem = String(filename.dropLast(4))
        let prefix = "\(yarnID.uuidString)-label-"
        guard stem.hasPrefix(prefix) else { return false }
        let remainder = String(stem.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: "-") else { return false }
        let ordinal = remainder[..<separator]
        let imageID = remainder[remainder.index(after: separator)...]
        return (ordinal == "1" || ordinal == "2") && UUID(uuidString: String(imageID)) != nil
    }

    private static func labelPhotoOrdinal(_ filename: String) -> Character? {
        guard filename.hasSuffix(".jpg") else { return nil }
        let stem = filename.dropLast(4)
        guard let marker = stem.range(of: "-label-") else { return nil }
        return stem[marker.upperBound...].first
    }

    private static func legacyLabelPhotoSlotID(_ filename: String) -> UUID? {
        guard filename.hasSuffix(".jpg") else { return nil }
        let stem = filename.dropLast(4)
        guard let marker = stem.range(of: "-label-") else { return nil }
        let suffix = stem[marker.upperBound...]
        guard suffix.count > 2,
              (suffix.first == "1" || suffix.first == "2"),
              suffix[suffix.index(after: suffix.startIndex)] == "-" else { return nil }
        return UUID(uuidString: String(suffix.dropFirst(2)))
    }

    private static func areValidLabelPhotoFilenames(_ filenames: [String], yarnID: UUID) -> Bool {
        guard filenames.count <= 2, Set(filenames).count == filenames.count else { return false }
        let prefix = "\(yarnID.uuidString)-label-"
        let ordinals = filenames.compactMap { filename -> Character? in
            guard isManagedLabelPhotoFilename(filename, yarnID: yarnID) else { return nil }
            return filename.dropFirst(prefix.count).first
        }
        return ordinals.count == filenames.count && Set(ordinals).count == ordinals.count
    }
}
