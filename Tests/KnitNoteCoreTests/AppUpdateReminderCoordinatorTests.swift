import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct AppUpdateReminderCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func checkRunsTheInjectedLookupOnlyOnceAcrossRepeatedCalls() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let probe = FetchProbe(result: testUpdate("1.5.2"))
        let coordinator = makeCoordinator(defaults: defaults) { country, platform in
            await probe.fetch(country: country, platform: platform)
        }

        await coordinator.checkIfNeeded()
        await coordinator.checkIfNeeded()

        #expect(await probe.callCount == 1)
        #expect(coordinator.pendingUpdate == testUpdate("1.5.2"))
    }

    @Test func newerPublicVersionPublishesOnePendingUpdate() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let expected = testUpdate("1.5.2")
        let coordinator = makeCoordinator(defaults: defaults) { _, _ in expected }

        await coordinator.checkIfNeeded()

        #expect(coordinator.pendingUpdate == expected)
    }

    @Test(arguments: ["1.5.2", "1.5.3", "not-a-version"])
    func equalOlderOrMalformedInstalledVersionPublishesNothing(_ installedVersion: String) async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let coordinator = makeCoordinator(
            installedVersion: installedVersion,
            defaults: defaults
        ) { _, _ in testUpdate("1.5.2") }

        await coordinator.checkIfNeeded()

        #expect(coordinator.pendingUpdate == nil)
    }

    @Test func disabledModeNeverCallsTheInjectedLookup() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let probe = FetchProbe(result: testUpdate("1.5.2"))
        let coordinator = makeCoordinator(enabled: false, defaults: defaults) { country, platform in
            await probe.fetch(country: country, platform: platform)
        }

        await coordinator.checkIfNeeded()

        #expect(await probe.callCount == 0)
        #expect(coordinator.pendingUpdate == nil)
    }

    @Test func missingLookupResultPublishesNothing() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let coordinator = makeCoordinator(defaults: defaults) { _, _ in
            nil as AvailableAppUpdate?
        }

        await coordinator.checkIfNeeded()

        #expect(coordinator.pendingUpdate == nil)
    }

    @Test func sevenDayDismissalSuppressesTheSameVersion() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let history = UpdateReminderHistory(defaults: defaults)
        history.recordLater(
            version: AppVersion("1.5.2")!,
            at: now.addingTimeInterval(-(6 * 86_400))
        )
        let coordinator = makeCoordinator(history: history) { _, _ in testUpdate("1.5.2") }

        await coordinator.checkIfNeeded()

        #expect(coordinator.pendingUpdate == nil)
    }

    @Test func higherVersionBypassesAnExistingDismissal() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let history = UpdateReminderHistory(defaults: defaults)
        history.recordLater(version: AppVersion("1.5.2")!, at: now)
        let coordinator = makeCoordinator(history: history) { _, _ in testUpdate("1.6.0") }

        await coordinator.checkIfNeeded()

        #expect(coordinator.pendingUpdate == testUpdate("1.6.0"))
    }

    @Test func remindLaterPersistsThePendingVersionAndFixedDateThenClearsPresentation() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let history = UpdateReminderHistory(defaults: defaults)
        let coordinator = makeCoordinator(history: history) { _, _ in testUpdate("1.5.2") }
        await coordinator.checkIfNeeded()

        coordinator.remindLater()

        #expect(history.dismissal == UpdateReminderDismissal(
            version: AppVersion("1.5.2")!,
            dismissedAt: now
        ))
        #expect(coordinator.pendingUpdate == nil)
    }

    @Test func openingTheStoreClearsPresentationWithoutWritingDefaults() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let coordinator = makeCoordinator(defaults: defaults) { _, _ in testUpdate("1.5.2") }
        await coordinator.checkIfNeeded()
        let defaultsBeforeAction = defaults.dictionaryRepresentation()

        coordinator.didOpenStore()

        #expect(coordinator.pendingUpdate == nil)
        #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation()).isEqual(
            to: defaultsBeforeAction
        ))
    }

    @Test func cancellationAfterTheLoaderStartsNeverPublishesItsResult() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let loader = SuspendedLoader()
        let coordinator = makeCoordinator(defaults: defaults) { _, _ in
            await loader.load()
        }
        let task = Task { await coordinator.checkIfNeeded() }
        while !(await loader.hasStarted) {
            await Task.yield()
        }

        task.cancel()
        await loader.finish(with: testUpdate("1.5.2"))
        await task.value

        #expect(coordinator.pendingUpdate == nil)
    }

    @Test func higherPriorityPresentationDefersWithoutConsumingThePendingUpdate() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let expected = testUpdate("1.5.2")
        let coordinator = makeCoordinator(defaults: defaults) { _, _ in expected }
        await coordinator.checkIfNeeded()
        let state = testPresentationState(activeOwner: .blockingStoreLoadError)

        #expect(!state.shouldPresentUpdate(hasPendingUpdate: coordinator.pendingUpdate != nil))
        #expect(coordinator.pendingUpdate == expected)
    }

    private func makeCoordinator(
        enabled: Bool = true,
        installedVersion: String = "1.5.1",
        defaults: UserDefaults? = nil,
        history: UpdateReminderHistory? = nil,
        fetch: @escaping @Sendable (String?, AppStorePlatform) async -> AvailableAppUpdate?
    ) -> AppUpdateReminderCoordinator {
        let history = history ?? UpdateReminderHistory(defaults: defaults ?? makeDefaults())
        return AppUpdateReminderCoordinator(
            enabled: enabled,
            installedVersion: { installedVersion },
            platform: .iPhone,
            countryCode: { "tw" },
            fetch: fetch,
            history: history,
            now: { now }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppUpdateReminderCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func clear(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: "updateReminder.dismissedVersion")
        defaults.removeObject(forKey: "updateReminder.dismissedAt")
    }

    private actor FetchProbe {
        private(set) var callCount = 0
        let result: AvailableAppUpdate?

        init(result: AvailableAppUpdate?) {
            self.result = result
        }

        func fetch(country: String?, platform: AppStorePlatform) -> AvailableAppUpdate? {
            callCount += 1
            return result
        }
    }

    private actor SuspendedLoader {
        private(set) var hasStarted = false
        private var continuation: CheckedContinuation<AvailableAppUpdate?, Never>?

        func load() async -> AvailableAppUpdate? {
            hasStarted = true
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(with update: AvailableAppUpdate?) {
            continuation?.resume(returning: update)
            continuation = nil
        }
    }
}

@Suite struct AppUpdatePresentationStateTests {
    @Test(arguments: PresentationPriorityOwner.allCases)
    func everyExistingRootPresentationOwnerDefersTheUpdate(
        _ owner: PresentationPriorityOwner
    ) {
        let state = testPresentationState(activeOwner: owner)

        #expect(state.higherPriorityPresentationActive)
        #expect(!state.shouldPresentUpdate(hasPendingUpdate: true))
    }

    @Test func updatePresentsOnlyWithPendingContentAndNoHigherPriorityOwner() {
        let state = testPresentationState(activeOwner: nil)

        #expect(!state.higherPriorityPresentationActive)
        #expect(state.shouldPresentUpdate(hasPendingUpdate: true))
        #expect(!state.shouldPresentUpdate(hasPendingUpdate: false))
    }
}

enum PresentationPriorityOwner: CaseIterable, Sendable, CustomTestStringConvertible {
    case blockingStoreLoadError
    case createProjectSheet
    case backupReminderAlert
    case backupSettingsSheet
    case patternInboxFailureAlert
    case pendingPatternSelectionSheet
    case unlockPaywallSheet

    var testDescription: String {
        switch self {
        case .blockingStoreLoadError: "blocking store load error"
        case .createProjectSheet: "create-project sheet"
        case .backupReminderAlert: "backup reminder alert"
        case .backupSettingsSheet: "backup settings sheet with restore confirmation"
        case .patternInboxFailureAlert: "pattern inbox failure alert with destructive discard"
        case .pendingPatternSelectionSheet: "pending pattern selection sheet"
        case .unlockPaywallSheet: "unlock paywall sheet"
        }
    }
}

private func testPresentationState(
    activeOwner: PresentationPriorityOwner?
) -> AppUpdatePresentationState {
    AppUpdatePresentationState(
        hasBlockingStoreLoadError: activeOwner == .blockingStoreLoadError,
        isCreateProjectSheetPresented: activeOwner == .createProjectSheet,
        isBackupReminderPresented: activeOwner == .backupReminderAlert,
        isBackupSettingsPresented: activeOwner == .backupSettingsSheet,
        hasPatternInboxFailure: activeOwner == .patternInboxFailureAlert,
        hasPendingPatternSelection: activeOwner == .pendingPatternSelectionSheet,
        isUnlockPaywallPresented: activeOwner == .unlockPaywallSheet
    )
}

private func testUpdate(_ version: String) -> AvailableAppUpdate {
    AvailableAppUpdate(
        version: AppVersion(version)!,
        displayVersion: version,
        storeURL: URL(string: "https://apps.apple.com/tw/app/id6793023054")!
    )
}
