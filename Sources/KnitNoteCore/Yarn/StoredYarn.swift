import Foundation

public enum YarnValidationError: Error, Equatable, Sendable {
    case emptyName
    case negativeInventory
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
}
