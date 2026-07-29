import Combine
import Foundation
import KnittingCalculatorCore

struct GaugeDraft: Codable, Equatable {
    var unit: GaugeLengthUnit
    var sampleWidth = ""
    var sampleStitches = ""
    var targetWidth = ""
    var sampleHeight = ""
    var sampleRows = ""
    var targetHeight = ""
}

struct OneRowAdjustmentDraft: Codable, Equatable {
    var currentStitches = ""
    var targetStitches = ""
    var reservesEdgeStitches = true
}

struct RowIntervalAdjustmentDraft: Codable, Equatable {
    var totalRows = ""
    var totalStitches = ""
    var operation: RowIntervalAdjustmentOperation = .increase
    var style: RowIntervalAdjustmentStyle = .singleSide
}

@MainActor
final class CalculatorPreferencesStore: ObservableObject {
    @Published var gauge: GaugeDraft {
        didSet { persist(gauge, forKey: Keys.gauge) }
    }
    @Published var oneRow: OneRowAdjustmentDraft {
        didSet { persist(oneRow, forKey: Keys.oneRow) }
    }
    @Published var rowInterval: RowIntervalAdjustmentDraft {
        didSet { persist(rowInterval, forKey: Keys.rowInterval) }
    }
    @Published var validCalculationCount: Int {
        didSet { defaults.set(validCalculationCount, forKey: Keys.validCalculationCount) }
    }
    @Published var ratingAttemptVersion: String? {
        didSet {
            if let ratingAttemptVersion {
                defaults.set(ratingAttemptVersion, forKey: Keys.ratingAttemptVersion)
            } else {
                defaults.removeObject(forKey: Keys.ratingAttemptVersion)
            }
        }
    }

    private enum Keys {
        static let gauge = "knittingCalculator.gauge"
        static let oneRow = "knittingCalculator.oneRow"
        static let rowInterval = "knittingCalculator.rowInterval"
        static let validCalculationCount = "knittingCalculator.validCalculationCount"
        static let ratingAttemptVersion = "knittingCalculator.ratingAttemptVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults, locale: Locale) {
        self.defaults = defaults
        gauge = Self.load(GaugeDraft.self, from: defaults, forKey: Keys.gauge)
            ?? GaugeDraft(unit: Self.initialUnit(for: locale))
        oneRow = Self.load(OneRowAdjustmentDraft.self, from: defaults, forKey: Keys.oneRow)
            ?? OneRowAdjustmentDraft()
        rowInterval = Self.load(RowIntervalAdjustmentDraft.self, from: defaults, forKey: Keys.rowInterval)
            ?? RowIntervalAdjustmentDraft()
        validCalculationCount = min(max(defaults.integer(forKey: Keys.validCalculationCount), 0), 5)
        ratingAttemptVersion = defaults.string(forKey: Keys.ratingAttemptVersion)
    }

    static func initialUnit(for locale: Locale) -> GaugeLengthUnit {
        locale.region?.identifier == "US" ? .inches : .centimeters
    }

    func recordValidCalculation() {
        validCalculationCount = min(validCalculationCount + 1, 5)
    }

    func markRatingAttempt(version: String) {
        ratingAttemptVersion = version
    }

    func resetDrafts() {
        gauge = GaugeDraft(unit: gauge.unit)
        oneRow = OneRowAdjustmentDraft()
        rowInterval = RowIntervalAdjustmentDraft()
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(
        _ type: T.Type,
        from defaults: UserDefaults,
        forKey key: String
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
