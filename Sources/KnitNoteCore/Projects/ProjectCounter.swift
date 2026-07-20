import Foundation

public enum CounterGridDeviceClass: Sendable {
    case phone
    case pad
}

public enum CounterGridLayoutPolicy {
    public static let sixColumnMinimumWidth = 780.0

    public static func columnCount(
        availableWidth: Double,
        deviceClass: CounterGridDeviceClass
    ) -> Int {
        switch deviceClass {
        case .phone:
            2
        case .pad:
            availableWidth >= sixColumnMinimumWidth ? 6 : 3
        }
    }
}

public enum CounterActionControlPolicy {
    public static let minimumTouchTarget = 44.0

    public static func hasPracticalTouchTarget(width: Double, height: Double) -> Bool {
        width >= minimumTouchTarget && height >= minimumTouchTarget
    }
}

public enum CounterAccessibilityPolicy {
    public static func actionLabel(
        format: String,
        counterName: String,
        currentValue: Int,
        locale: Locale
    ) -> String {
        String(
            format: format,
            locale: locale,
            counterName,
            currentValue
        )
    }
}

public struct ProjectCounter: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let defaultOrdinal: Int
    public private(set) var customName: String?
    public private(set) var value: Int
    public private(set) var rowNotes: [RowNote]

    public init(
        id: UUID = UUID(),
        defaultOrdinal: Int,
        customName: String? = nil,
        value: Int = 0,
        rowNotes: [RowNote] = []
    ) {
        let cleanName = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.defaultOrdinal = defaultOrdinal
        self.customName = cleanName?.isEmpty == false ? cleanName : nil
        self.value = max(0, value)
        self.rowNotes = rowNotes
    }

    enum CodingKeys: String, CodingKey {
        case id, defaultOrdinal, customName, value, rowNotes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            defaultOrdinal: try container.decode(Int.self, forKey: .defaultOrdinal),
            customName: try container.decodeIfPresent(String.self, forKey: .customName),
            value: try container.decode(Int.self, forKey: .value),
            rowNotes: try container.decode([RowNote].self, forKey: .rowNotes)
        )
    }

    mutating func increment() -> Bool {
        guard value < .max else { return false }
        value += 1
        return true
    }

    mutating func decrement() -> Bool {
        guard value > 0 else { return false }
        value -= 1
        return true
    }

    mutating func reset() -> Bool {
        guard value != 0 else { return false }
        value = 0
        return true
    }

    mutating func update(name: String?, value: Int) -> Bool {
        let didRename = rename(to: name)
        let normalizedValue = max(0, value)
        let didChangeValue = self.value != normalizedValue
        self.value = normalizedValue
        return didRename || didChangeValue
    }

    mutating func rename(to name: String?) -> Bool {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = cleanName?.isEmpty == false ? cleanName : nil
        guard customName != newName else { return false }
        customName = newName
        return true
    }

    func note(row: Int) -> RowNote? {
        rowNotes.first { $0.row == row }
    }

    mutating func saveNote(row: Int, text: String, now: Date) throws -> Bool {
        guard row >= 0 else { throw ProjectValidationError.emptyName }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return deleteNote(row: row) }

        if let index = rowNotes.firstIndex(where: { $0.row == row }) {
            guard rowNotes[index].text != clean else { return false }
            rowNotes[index].text = clean
            rowNotes[index].updatedAt = now
        } else {
            rowNotes.append(RowNote(row: row, text: clean, createdAt: now, updatedAt: now))
        }
        return true
    }

    mutating func deleteNote(row: Int) -> Bool {
        let oldCount = rowNotes.count
        rowNotes.removeAll { $0.row == row }
        return rowNotes.count != oldCount
    }
}
