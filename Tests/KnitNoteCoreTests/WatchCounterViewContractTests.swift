import Foundation
import Testing

@Suite struct WatchCounterViewContractTests {
    @Test func rootReplacesTheSampleWithTwoLevelProjectNavigationAndVisibleErrors() throws {
        let root = try source("KnitNoteWatch/WatchCounterView.swift")

        #expect(root.contains("NavigationStack"))
        #expect(root.contains("ProjectListView("))
        #expect(root.contains("coordinator: coordinator"))
        #expect(root.contains(".navigationDestination(for: UUID.self)"))
        #expect(root.contains("ProjectCountersView("))
        #expect(root.contains("projectID: projectID"))
        #expect(root.contains("coordinator.localizedErrorReason"))
        #expect(root.contains("Text(verbatim: errorReason)"))
        #expect(root.contains("onStoreScreenshotReady: onStoreScreenshotReady"))
        #expect(!root.contains("if path.isEmpty"))
        #expect(!root.contains(".lineLimit("))

        let list = try source("KnitNoteWatch/ProjectListView.swift")
        #expect(list.contains("let onStoreScreenshotReady: @MainActor @Sendable () -> Void"))
        #expect(list.contains("onStoreScreenshotReady()"))

        let counters = try source("KnitNoteWatch/ProjectCountersView.swift")
        let counterListStart = try #require(counters.range(of: "private func counterList"))
        let counterListSource = counters[counterListStart.lowerBound...]
        #expect(counterListSource.contains("onStoreScreenshotReady()"))
        #expect(!counters.contains("coordinator.selectProject(projectID)\n            onStoreScreenshotReady()"))
        #expect(root.contains("Color(watchTheme: WatercolorPalette.sky)"))
        #expect(!root.contains("KnittingProject"))
        #expect(!root.contains("sample.projectName"))
    }

    @Test func projectListUsesSnapshotOrderStableIDsAndReadableRows() throws {
        let source = try source("KnitNoteWatch/ProjectListView.swift")

        #expect(source.contains("coordinator.snapshot?.projects"))
        #expect(source.contains("ForEach(projects)"))
        #expect(source.contains("NavigationLink(value: project.id)"))
        #expect(source.contains("coordinator.selectProject(project.id)"))
        #expect(!source.contains(".lineLimit("))
        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(source.contains("Image(systemName: \"lock.fill\")"))
        #expect(source.contains("Text(\"watch.project.completed\")"))
        #expect(source.contains("minHeight: 44"))
    }

    @Test func counterRowsKeepFullNamesAndVisibleNonColorStatus() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(source.contains("ForEach(project.counters)"))
        #expect(source.contains(".onTapGesture"))
        #expect(source.contains(".onLongPressGesture"))
        #expect(source.contains(".confirmationDialog("))
        #expect(source.contains(".disabled(project.isCompleted)"))
        #expect(source.contains("coordinator.hasPending(projectID: project.id, counterID: counter.id)"))
        #expect(source.contains("Image(systemName: \"arrow.triangle.2.circlepath\")"))
        #expect(source.contains("Text(\"watch.sync.pending\")"))
        #expect(source.contains("Image(systemName: \"lock.fill\")"))
        #expect(source.contains("Text(\"watch.project.completed\")"))
        #expect(!source.contains(".lineLimit("))
        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(source.contains("minHeight: 64"))
    }

    @Test func dialogDismissesAndRevalidatesWhenItsSnapshotTargetChanges() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(source.contains("private var actionableCounterID: UUID?"))
        #expect(source.components(separatedBy: "!project.isCompleted").count - 1 >= 2)
        #expect(source.contains("project.counters.contains(where: { $0.id == actionCounterID })"))
        #expect(source.contains("if let counterID = actionableCounterID"))
        #expect(source.contains(".onChange(of: coordinator.snapshot)"))
        #expect(source.contains("dismissInvalidActionIfNeeded()"))
        #expect(source.contains("private func currentActiveProject(containing counterID: UUID)"))
        #expect(source.contains("guard let project = currentActiveProject(containing: counterID)"))
    }

    @Test func accessibilitySpeaksStatusAndOnlyActiveRowsExposeMutationActions() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(source.contains(".accessibilityLabel(Text(verbatim:"))
        #expect(source.contains(".accessibilityValue(counterAccessibilityValue("))
        #expect(source.contains("Text(\"watch.sync.pending\")"))
        #expect(source.contains("Text(\"watch.project.completed\")"))
        #expect(source.contains("Text(\"watch.sync.error.projectCompleted\")"))
        #expect(source.contains("if project.isCompleted {"))
        #expect(source.contains("private func activeCounterRow"))
        #expect(source.components(separatedBy: ".accessibilityAction(named:").count - 1 == 3)
        #expect(source.contains("perform(.increment, counterID: counter.id)"))
        #expect(source.contains("perform(.decrement, counterID: counter.id)"))
        #expect(source.contains("perform(.reset, counterID: counter.id)"))
    }

    @Test func expiredEntitlementIsReadOnlyAndGuidesUnlockOnIPhone() throws {
        let viewSource = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(viewSource.contains("coordinator.canMutate"))
        #expect(viewSource.contains("Text(\"watch.entitlement.unlockOnIPhone\")"))
        #expect(viewSource.contains(".disabled(!canMutate)"))
        #expect(viewSource.contains("watch.entitlement.unlockOnIPhone"))
        #expect(viewSource.contains("guard canMutate"))

        let coordinator = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")
        #expect(coordinator.contains("state.canMutate(now:"))
        #expect(coordinator.contains("state.nextDeliverableCommand(now: now())"))
    }

    @Test func reminderQueueRendersOneSchemaFourOccurrenceWithOnlyPhaseAppropriateActions() throws {
        let counters = try source("KnitNoteWatch/ProjectCountersView.swift")
        let queue = try source("KnitNoteWatch/KnittingReminderQueueView.swift")

        #expect(counters.contains("KnittingReminderQueueView("))
        #expect(counters.contains("project.reminderQueue"))
        #expect(queue.contains("queue.first"))
        #expect(queue.contains("currentIndex"))
        #expect(queue.contains("totalCount"))
        #expect(queue.contains("occurrence.kind"))
        #expect(queue.contains("Text(verbatim: text)"))
        #expect(queue.contains("occurrence.originalTarget"))
        #expect(queue.contains("case .initial:"))
        #expect(queue.contains("case .deferredOnce:"))
        #expect(queue.contains("coordinator.completeReminder("))
        #expect(queue.contains("coordinator.deferReminderOnce("))
        #expect(queue.contains("coordinator.skipReminder("))
        #expect(!queue.contains("TextField("))
        #expect(!queue.contains("addKnittingReminder"))
        #expect(!queue.contains("stopReminder"))
        #expect(!queue.contains("rule"))
    }

    @Test func reminderQueueUsesFullPayloadAccessibilityAndPendingDisablement() throws {
        let queue = try source("KnitNoteWatch/KnittingReminderQueueView.swift")

        #expect(queue.contains("projectID: project.id"))
        #expect(queue.contains("counterID: reminder.counterID"))
        #expect(queue.contains("reminderID: occurrence.reminderID"))
        #expect(queue.contains("occurrenceID: occurrence.id"))
        #expect(queue.contains("observedRevision: reminder.mutationRevision"))
        #expect(queue.contains(".frame(minHeight: 44)"))
        #expect(queue.contains(".disabled(isPending"))
        #expect(queue.contains(".accessibilityLabel("))
        #expect(queue.contains(".accessibilityHint("))
        #expect(queue.contains("queuePosition"))
        #expect(queue.contains(".accessibilityElement(children: .contain)"))
        #expect(queue.contains(".accessibilityElement(children: .ignore)"))
        #expect(!queue.contains(".accessibilityElement(children: .combine)"))
        #expect(!queue.contains("legacy"))
    }

    @Test func reminderQueueRoutesEverySpokenAndVisibleLabelThroughWatchLocalizationKeys() throws {
        let queue = try source("KnitNoteWatch/KnittingReminderQueueView.swift")
        let data = try Data(contentsOf: rootURL().appending(path: "KnitNoteWatch/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let requiredKeys = [
            "watch.reminder.accessibility.summary",
            "watch.reminder.action.complete", "watch.reminder.action.complete.hint",
            "watch.reminder.action.defer", "watch.reminder.action.defer.hint",
            "watch.reminder.action.skip", "watch.reminder.action.skip.hint",
            "watch.reminder.kind.increase", "watch.reminder.kind.decrease",
            "watch.reminder.kind.changeYarn", "watch.reminder.kind.cable",
            "watch.reminder.kind.buttonhole", "watch.reminder.kind.measure",
            "watch.reminder.kind.custom", "watch.reminder.phase.initial",
            "watch.reminder.phase.deferred", "watch.reminder.queuePosition",
            "watch.reminder.target",
        ]

        for key in requiredKeys {
            #expect(queue.contains("\"\(key)\""))
            let entry = strings[key] as? [String: Any]
            #expect(localizedValue("en", in: entry?["localizations"] as? [String: Any]) != nil)
        }
        #expect(queue.contains("LocaleAwareText.string"))
        #expect(queue.contains("LocaleAwareText.format"))
        #expect(!queue.contains("\"Complete\""))
        #expect(!queue.contains("\"Remind Next Row\""))
        #expect(!queue.contains("\"Skip This Time\""))
        #expect(!queue.contains("Row \\("))
        #expect(!queue.contains("\"Initial\""))
        #expect(!queue.contains("\"Deferred\""))
    }

    @Test func reminderQueueDoesNotLeaveTheLegacyCardOrBridgeInProductionPaths() throws {
        let counters = try source("KnitNoteWatch/ProjectCountersView.swift")
        let coordinator = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")
        let builder = try source("Sources/KnitNoteCore/WatchSync/WatchSnapshotBuilder.swift")
        let models = try source("Sources/KnitNoteCore/WatchSync/WatchSyncModels.swift")

        #expect(!counters.contains("reminderConfirmation("))
        #expect(!counters.contains("counter.reminder.stop"))
        #expect(!coordinator.contains("legacyCompatibilityToken("))
        #expect(!coordinator.contains("legacyWatchUICommand("))
        #expect(!builder.contains("legacyCardReminder("))
        #expect(models.contains("#if DEBUG"))
        #expect(models.contains("case 2:"))
    }

    @Test func newlyVisibleQueueOccurrencesPlayOneNotificationHapticAfterPersistence() throws {
        let source = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")
        let enqueue = try #require(sourceSection(
            source,
            from: "private func enqueue(",
            to: "private func persistThenPublish"
        ))

        #expect(source.contains("import WatchKit"))
        #expect(enqueue.contains("candidate.takeNewQueueHeadHapticOccurrenceIDs()"))
        #expect(enqueue.contains("guard persistThenPublish(candidate) else { return }"))
        #expect(enqueue.contains("playHaptic()"))
        #expect(source.contains("playHaptic: @escaping () -> Void"))
        #expect(source.components(separatedBy: "WKInterfaceDevice.current().play(.notification)").count - 1 == 1)
        let persistence = try #require(enqueue.range(of: "guard persistThenPublish(candidate) else { return }"))
        let haptic = try #require(enqueue.range(of: "playHaptic()"))
        #expect(persistence.lowerBound < haptic.lowerBound)

        let selection = try #require(source.range(of: "func selectProject(_ projectID: UUID?)"))
        let selectionBody = String(source[selection.lowerBound...])
        #expect(selectionBody.contains("candidate.takeNewQueueHeadHapticOccurrenceIDs()"))
        #expect(selectionBody.contains("guard persistThenPublish(candidate) else { return }"))

        let acknowledgement = try #require(sourceSection(
            source,
            from: "private func handleAcknowledgement",
            to: "private func beginHandshakeAndReplay"
        ))
        #expect(acknowledgement.contains("candidate.takeNewQueueHeadHapticOccurrenceIDs()"))
        #expect(acknowledgement.contains("guard persistThenPublish(candidate) else"))
        #expect(acknowledgement.contains("playHaptic()"))
    }

    @Test func unlockGuidanceIsLocalizedInEnglishAndTraditionalChinese() throws {
        let data = try Data(contentsOf: rootURL().appending(
            path: "KnitNoteWatch/Localizable.xcstrings"
        ))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = catalog?["strings"] as? [String: Any]
        let entry = strings?["watch.entitlement.unlockOnIPhone"] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]

        #expect(localizedValue("en", in: localizations) == "Unlock on iPhone")
        #expect(localizedValue("zh-Hant", in: localizations) == "請在 iPhone 上解鎖")
    }

    @Test func DutchWatchCounterRemindersUseReviewedCompactCopy() throws {
        let data = try Data(contentsOf: rootURL().appending(
            path: "KnitNoteWatch/Localizable.xcstrings"
        ))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        #expect(try directCatalogValue("counter.reminder.complete", language: "nl", strings: strings) == "Deze herinnering voltooien")
        #expect(try directCatalogValue("counter.reminder.complete.hint", language: "nl", strings: strings) == "Bevestigt de gepasseerde toeren.")
        #expect(try directCatalogValue("counter.reminder.stop", language: "nl", strings: strings) == "Herinnering stoppen")
        #expect(try directCatalogValue("counter.reminder.stop.hint", language: "nl", strings: strings) == "Schakelt deze herinnering uit en wist alle openstaande toerherinneringen.")
        #expect(try directCatalogValue("counter.reminder.reached", language: "nl", strings: strings) == "Toer %lld bereikt.")
        #expect(try pluralCatalogValue("counter.reminder.crossedCount", language: "nl", category: "one", strings: strings) == "%lld herinnering gepasseerd")
        #expect(try pluralCatalogValue("counter.reminder.crossedCount", language: "nl", category: "other", strings: strings) == "%lld herinneringen gepasseerd")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: rootURL().appending(path: path), encoding: .utf8)
    }

    private func sourceSection(
        _ source: String,
        from start: String,
        to end: String
    ) -> Substring? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(
                  of: end,
                  range: startRange.upperBound..<source.endIndex
              ) else { return nil }
        return source[startRange.lowerBound..<endRange.lowerBound]
    }

    private func rootURL() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func localizedValue(
        _ language: String,
        in localizations: [String: Any]?
    ) -> String? {
        let localization = localizations?[language] as? [String: Any]
        let unit = localization?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    private func directCatalogValue(
        _ key: String,
        language: String,
        strings: [String: Any]
    ) throws -> String {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        return try #require(localizedValue(language, in: localizations))
    }

    private func pluralCatalogValue(
        _ key: String,
        language: String,
        category: String,
        strings: [String: Any]
    ) throws -> String {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let localization = try #require(localizations[language] as? [String: Any])
        let variations = try #require(localization["variations"] as? [String: Any])
        let plural = try #require(variations["plural"] as? [String: Any])
        let variation = try #require(plural[category] as? [String: Any])
        let unit = try #require(variation["stringUnit"] as? [String: Any])
        return try #require(unit["value"] as? String)
    }
}
