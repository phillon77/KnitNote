import Foundation

@MainActor
struct AppSessionWatchResources {
    let coordinator: PhoneWatchSyncCoordinator
    let adapter: PhoneWatchSession
}

@MainActor
struct AppSessionPresentationResources {
    let patternInboxProcessor: PatternInboxProcessor
    let patternBackupReminderPresenter: PatternBackupReminderPresenter
    let reminderPresentationStore: KnittingReminderPresentationStore
    let watch: AppSessionWatchResources?
}

/// Shared launch preferences/services remain outside the session subtree.
/// Neither this composition nor its UUID establishes account readiness.
@MainActor
struct AppSessionLaunchResources {
    let session: AppSessionResources
    let entitlementCoordinator: EntitlementCoordinator
    let languageSelectionProjection: LanguageSelectionProjection?
}

/// Constructed lazily only for the existing local shipping route. The update
/// response fixture does not change that route into an isolated App session.
@MainActor
struct AppSessionLocalDependencies {
    let store: JSONProjectStore
    let entitlementCoordinator: EntitlementCoordinator
    let languageSelectionProjection: LanguageSelectionProjection?
    let makeWatch: (JSONProjectStore) throws -> AppSessionWatchResources?
}

@MainActor
enum AppSessionComposition {
    /// makeWatch must return dormant components, without starting producers.
    /// Constructors accept no imports, callbacks or native work: on failure
    /// there is no accepted work to join. Start happens after owner publication.
    static func make(
        store: JSONProjectStore,
        backupHistory: BackupHistory,
        makeWatch: (JSONProjectStore) throws -> AppSessionWatchResources?
    ) throws -> AppSessionResources {
        guard !store.isSessionWriteRevoked else { throw AppSessionOwner.Failure.stoppedSession }
        let watch = try makeWatch(store)
        let backup = PatternBackupReminderPresenter(history: backupHistory)
        let reminders = KnittingReminderPresentationStore()
        let inbox = PatternInboxProcessor(store: store, backupReminderPresenter: backup)
        let presentation = AppSessionPresentationResources(
            patternInboxProcessor: inbox,
            patternBackupReminderPresenter: backup,
            reminderPresentationStore: reminders,
            watch: watch
        )
        return try AppSessionResources(store: store, presentation: presentation) { _ in
            var producers: [any AppSessionProducer] = [inbox]
            if let watch {
                producers.append(watch.coordinator)
                producers.append(watch.adapter)
            }
            return producers
        }
    }

    /// Receives an already-resolved screenshot path. Invalid process requests
    /// are rejected by the App before this route and before any live factory.
    static func makeLaunch(
        screenshotBaseDirectory: URL?,
        backupHistory: BackupHistory,
        makeScreenshotStore: (URL, EntitlementCoordinator) throws -> JSONProjectStore,
        makeLocal: () throws -> AppSessionLocalDependencies
    ) throws -> AppSessionLaunchResources {
        if let screenshotBaseDirectory {
            let entitlement = EntitlementCoordinator.configured(screenshotMode: true)
            let store = try makeScreenshotStore(screenshotBaseDirectory, entitlement)
            return AppSessionLaunchResources(
                session: try make(store: store, backupHistory: backupHistory, makeWatch: { _ in nil }),
                entitlementCoordinator: entitlement,
                languageSelectionProjection: nil
            )
        }
        let local = try makeLocal()
        return AppSessionLaunchResources(
            session: try make(store: local.store, backupHistory: backupHistory, makeWatch: local.makeWatch),
            entitlementCoordinator: local.entitlementCoordinator,
            languageSelectionProjection: local.languageSelectionProjection
        )
    }
}
