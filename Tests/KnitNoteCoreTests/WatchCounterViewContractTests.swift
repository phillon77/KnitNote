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

    @Test func pendingReminderConfirmationHasOnlyCompleteAndStopActions() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")
        let confirmation = try #require(sourceSection(
            source,
            from: "private func reminderConfirmation(",
            to: "private func activeCounterRow"
        ))

        #expect(confirmation.contains("reminder.pending"))
        #expect(confirmation.contains("Text(verbatim: message)"))
        #expect(confirmation.contains("Button(\"counter.reminder.complete\")"))
        #expect(confirmation.contains("Button(\"counter.reminder.stop\", role: .destructive)"))
        #expect(confirmation.components(separatedBy: "Button(").count - 1 == 2)
        #expect(confirmation.contains("observedPendingCount: pending.occurrenceCount"))
        #expect(!confirmation.localizedCaseInsensitiveContains("snooze"))
    }

    @Test func pendingReminderCountsUseLocaleAwareIntegerFormattingAndPluralSelection() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")
        let confirmation = try #require(sourceSection(
            source,
            from: "private func reminderConfirmation(",
            to: "private func activeCounterRow"
        ))

        #expect(source.contains("@Environment(\\.locale)"))
        #expect(confirmation.contains("LocaleAwareText.format("))
        #expect(confirmation.contains("\"counter.reminder.reached\""))
        #expect(confirmation.contains("pending.lastTarget"))
        #expect(confirmation.contains("LocaleAwareText.interpolated("))
        #expect(confirmation.contains("\"counter.reminder.crossedCount\""))
        #expect(confirmation.contains("pending.occurrenceCount"))
        #expect(!confirmation.contains("Text(\"counter.reminder.reached\")"))
        #expect(!confirmation.contains("Text(\"counter.reminder.crossedCount\")"))
    }

    @Test func localIncrementCrossingPlaysOneNotificationHapticAfterPersistence() throws {
        let source = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")
        let enqueue = try #require(sourceSection(
            source,
            from: "private func enqueue(",
            to: "private func persistThenPublish"
        ))

        #expect(source.contains("import WatchKit"))
        #expect(enqueue.contains("let previouslyVisibleReminderIDs"))
        #expect(enqueue.contains("let newlyVisibleReminderIDs"))
        #expect(enqueue.contains("newlyVisibleReminderIDs.subtracting(previouslyVisibleReminderIDs)"))
        #expect(enqueue.contains("guard persistThenPublish(candidate) else { return }"))
        #expect(enqueue.contains("WKInterfaceDevice.current().play(.notification)"))
        #expect(source.components(separatedBy: "WKInterfaceDevice.current().play(.notification)").count - 1 == 1)
        let persistence = try #require(enqueue.range(of: "guard persistThenPublish(candidate) else { return }"))
        let haptic = try #require(enqueue.range(of: "WKInterfaceDevice.current().play(.notification)"))
        #expect(persistence.lowerBound < haptic.lowerBound)
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
}
