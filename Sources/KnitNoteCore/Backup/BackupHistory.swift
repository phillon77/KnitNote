import Foundation

public struct BackupHistory {
    public enum ExportResult: Sendable, Equatable {
        case success
        case cancelled
        case failure
    }

    private enum Key {
        static let lastSuccessfulExportAt = "backup.lastSuccessfulExportAt"
        static let patternReminderShown = "patterns.backupReminderShown"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastSuccessfulExportAt: Date? {
        guard defaults.object(forKey: Key.lastSuccessfulExportAt) != nil else {
            return nil
        }
        return Date(
            timeIntervalSince1970: defaults.double(forKey: Key.lastSuccessfulExportAt)
        )
    }

    public var hasShownPatternReminder: Bool {
        defaults.bool(forKey: Key.patternReminderShown)
    }

    public mutating func recordExportResult(_ result: ExportResult, at date: Date = .now) {
        guard result == .success else { return }
        defaults.set(date.timeIntervalSince1970, forKey: Key.lastSuccessfulExportAt)
    }

    public mutating func markPatternReminderShown() {
        defaults.set(true, forKey: Key.patternReminderShown)
    }
}
