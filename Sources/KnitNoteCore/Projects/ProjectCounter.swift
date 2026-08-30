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
    public private(set) var mutationRevision: UInt64
    public private(set) var rowNotes: [RowNote]
    public private(set) var reminder: CounterReminder?

    public init(
        id: UUID = UUID(),
        defaultOrdinal: Int,
        customName: String? = nil,
        value: Int = 0,
        mutationRevision: UInt64 = 0,
        rowNotes: [RowNote] = [],
        reminder: CounterReminder? = nil
    ) {
        let cleanName = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.defaultOrdinal = defaultOrdinal
        self.customName = cleanName?.isEmpty == false ? cleanName : nil
        self.value = max(0, value)
        self.mutationRevision = mutationRevision
        self.rowNotes = rowNotes
        self.reminder = reminder.flatMap {
            CounterReminder.isValid($0, at: self.value) ? $0 : nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, defaultOrdinal, customName, value, mutationRevision, rowNotes, reminder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int.self, forKey: .value)
        let reminder = try container.decodeIfPresent(CounterReminder.self, forKey: .reminder)
        if let reminder, !CounterReminder.isValid(reminder, at: value) {
            throw DecodingError.dataCorruptedError(
                forKey: .reminder,
                in: container,
                debugDescription: "Counter reminder is invalid."
            )
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            defaultOrdinal: try container.decode(Int.self, forKey: .defaultOrdinal),
            customName: try container.decodeIfPresent(String.self, forKey: .customName),
            value: value,
            mutationRevision: try container.decodeIfPresent(
                UInt64.self,
                forKey: .mutationRevision
            ) ?? 0,
            rowNotes: try container.decode([RowNote].self, forKey: .rowNotes),
            reminder: reminder
        )
    }

    public func displayName(locale: Locale) -> String {
        customName ?? String(
            format: String(
                localized: "counter.defaultName",
                defaultValue: "Counter %lld",
                bundle: .main,
                locale: locale
            ),
            locale: locale,
            defaultOrdinal
        )
    }

    mutating func increment() -> Bool {
        guard value < .max else { return false }
        value += 1
        mutationRevision &+= 1
        return true
    }

    mutating func decrement() -> Bool {
        guard value > 0 else { return false }
        value -= 1
        mutationRevision &+= 1
        return true
    }

    mutating func reset() -> Bool {
        guard value != 0 else { return false }
        value = 0
        mutationRevision &+= 1
        return true
    }

    mutating func update(name: String?, value: Int) -> Bool {
        let didRename = rename(to: name)
        let normalizedValue = max(0, value)
        let didChangeValue = self.value != normalizedValue
        self.value = normalizedValue
        if didChangeValue {
            mutationRevision &+= 1
        }
        return didRename || didChangeValue
    }

    public mutating func applyValue(_ value: Int) -> CounterMutationOutcome? {
        let oldValue = self.value
        let newValue = max(0, value)
        guard oldValue != newValue else { return nil }

        self.value = newValue
        if let reminder {
            let evaluation = CounterReminderEvaluator.applyingUpwardChange(
                from: oldValue,
                to: newValue,
                reminder: reminder
            )
            self.reminder = evaluation.updatedReminder
            mutationRevision &+= 1
            return CounterMutationOutcome(
                oldValue: oldValue,
                newValue: newValue,
                pendingReminder: evaluation.newlyPending
            )
        }

        mutationRevision &+= 1
        return CounterMutationOutcome(oldValue: oldValue, newValue: newValue, pendingReminder: nil)
    }

    public mutating func configureReminder(_ draft: CounterReminderDraft) {
        reminder = CounterReminder(draft: draft, anchorValue: value)
    }

    public mutating func completePendingReminder(id: UUID, observedCount: Int) -> Bool {
        guard var reminder, reminder.completePending(id: id, observedCount: observedCount) else {
            return false
        }
        self.reminder = reminder
        return true
    }

    public mutating func stopReminder(id: UUID) -> Bool {
        guard var reminder, reminder.stop(id: id) else { return false }
        self.reminder = reminder
        return true
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
