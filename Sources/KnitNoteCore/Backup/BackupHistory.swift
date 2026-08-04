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

public struct PatternBackupReminderCoordinator {
    private var history: BackupHistory
    public private(set) var isPresented = false
    public private(set) var isShowingBackupSettings = false

    public init(history: BackupHistory = .init()) {
        self.history = history
    }

    public mutating func accept(_ outcome: PatternImportOutcome) {
        accept([outcome])
    }

    public mutating func accept(_ outcomes: [PatternImportOutcome]) {
        guard !history.hasShownPatternReminder,
              outcomes.contains(where: { outcome in
                  if case .created = outcome { return true }
                  return false
              })
        else { return }
        presentReminder()
    }

    public mutating func acceptCreatedPattern() {
        guard !history.hasShownPatternReminder else { return }
        presentReminder()
    }

    private mutating func presentReminder() {
        isPresented = true
    }

    public mutating func dismiss(openBackupSettings: Bool) {
        guard isPresented else { return }
        history.markPatternReminderShown()
        isPresented = false
        isShowingBackupSettings = openBackupSettings
    }

    public mutating func closeBackupSettings() {
        isShowingBackupSettings = false
    }
}
