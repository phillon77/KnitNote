import Combine
import Foundation

public struct AppUpdatePresentationState: Equatable, Sendable {
    public let hasBlockingStoreLoadError: Bool
    public let isCreateProjectSheetPresented: Bool
    public let isBackupReminderPresented: Bool
    public let isBackupSettingsPresented: Bool
    public let hasPatternInboxFailure: Bool
    public let hasPendingPatternSelection: Bool
    public let isUnlockPaywallPresented: Bool

    public init(
        hasBlockingStoreLoadError: Bool,
        isCreateProjectSheetPresented: Bool,
        isBackupReminderPresented: Bool,
        isBackupSettingsPresented: Bool,
        hasPatternInboxFailure: Bool,
        hasPendingPatternSelection: Bool,
        isUnlockPaywallPresented: Bool
    ) {
        self.hasBlockingStoreLoadError = hasBlockingStoreLoadError
        self.isCreateProjectSheetPresented = isCreateProjectSheetPresented
        self.isBackupReminderPresented = isBackupReminderPresented
        self.isBackupSettingsPresented = isBackupSettingsPresented
        self.hasPatternInboxFailure = hasPatternInboxFailure
        self.hasPendingPatternSelection = hasPendingPatternSelection
        self.isUnlockPaywallPresented = isUnlockPaywallPresented
    }

    public var higherPriorityPresentationActive: Bool {
        hasBlockingStoreLoadError
            || isCreateProjectSheetPresented
            || isBackupReminderPresented
            || isBackupSettingsPresented
            || hasPatternInboxFailure
            || hasPendingPatternSelection
            || isUnlockPaywallPresented
    }

    public func shouldPresentUpdate(hasPendingUpdate: Bool) -> Bool {
        hasPendingUpdate && !higherPriorityPresentationActive
    }
}

@MainActor
public final class AppUpdateReminderCoordinator: ObservableObject {
    @Published public private(set) var pendingUpdate: AvailableAppUpdate?

    private let enabled: Bool
    private let installedVersion: () -> String?
    private let platform: AppStorePlatform
    private let countryCode: @Sendable () async -> String?
    private let fetch: @Sendable (String?, AppStorePlatform) async -> AvailableAppUpdate?
    private let history: UpdateReminderHistory
    private let now: () -> Date
    private var didCheck = false

    public init(
        enabled: Bool,
        installedVersion: @escaping () -> String?,
        platform: AppStorePlatform,
        countryCode: @escaping @Sendable () async -> String?,
        fetch: @escaping @Sendable (String?, AppStorePlatform) async -> AvailableAppUpdate?,
        history: UpdateReminderHistory,
        now: @escaping () -> Date = { .now }
    ) {
        self.enabled = enabled
        self.installedVersion = installedVersion
        self.platform = platform
        self.countryCode = countryCode
        self.fetch = fetch
        self.history = history
        self.now = now
    }

    public func checkIfNeeded() async {
        guard enabled, !didCheck else { return }
        didCheck = true

        guard let installedVersion = installedVersion().flatMap(AppVersion.init) else {
            return
        }
        let countryCode = await countryCode()
        guard !Task.isCancelled else { return }
        guard let availableUpdate = await fetch(countryCode, platform) else { return }
        guard !Task.isCancelled else { return }
        guard UpdateReminderPolicy.shouldPresent(
            installed: installedVersion,
            available: availableUpdate.version,
            dismissal: history.dismissal,
            now: now()
        ) else { return }

        pendingUpdate = availableUpdate
    }

    public func remindLater() {
        guard let pendingUpdate else { return }
        history.recordLater(version: pendingUpdate.version, at: now())
        self.pendingUpdate = nil
    }

    public func didOpenStore() {
        pendingUpdate = nil
    }
}
