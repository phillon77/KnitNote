import Foundation

public struct UpdateReminderDismissal: Equatable, Sendable {
    public let version: AppVersion
    public let dismissedAt: Date

    public init(version: AppVersion, dismissedAt: Date) {
        self.version = version
        self.dismissedAt = dismissedAt
    }
}

public enum UpdateReminderPolicy {
    public static let snoozeInterval: TimeInterval = 7 * 86_400

    public static func shouldPresent(
        installed: AppVersion,
        available: AppVersion,
        dismissal: UpdateReminderDismissal?,
        now: Date
    ) -> Bool {
        guard available > installed else { return false }
        guard let dismissal else { return true }
        guard available <= dismissal.version else { return true }
        return now.timeIntervalSince(dismissal.dismissedAt) >= snoozeInterval
    }
}

public struct UpdateReminderHistory {
    private enum Key {
        static let dismissedVersion = "updateReminder.dismissedVersion"
        static let dismissedAt = "updateReminder.dismissedAt"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var dismissal: UpdateReminderDismissal? {
        let storedVersion = defaults.string(forKey: Key.dismissedVersion)
        let storedTimestamp = defaults.object(forKey: Key.dismissedAt) as? Double

        guard storedVersion != nil || storedTimestamp != nil else { return nil }
        guard
            let storedVersion,
            let version = AppVersion(storedVersion),
            let storedTimestamp,
            storedTimestamp.isFinite
        else {
            clearDismissal()
            return nil
        }

        return UpdateReminderDismissal(
            version: version,
            dismissedAt: Date(timeIntervalSince1970: storedTimestamp)
        )
    }

    public func recordLater(version: AppVersion, at date: Date = .now) {
        defaults.set(version.displayString, forKey: Key.dismissedVersion)
        defaults.set(date.timeIntervalSince1970, forKey: Key.dismissedAt)
    }

    private func clearDismissal() {
        defaults.removeObject(forKey: Key.dismissedVersion)
        defaults.removeObject(forKey: Key.dismissedAt)
    }
}
