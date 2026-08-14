import Foundation
import Testing

@Suite struct AppUpdateReminderViewContractTests {
    @Test func updateAlertOwnsLocalizedCopyActionsBlockersAndActiveSceneCheck() throws {
        let source = try repositorySource("KnitNote/App/RootView.swift")

        #expect(try updatePresentationFailures(in: source).isEmpty)
    }

    @Test(arguments: [
        Mutation("later action", "appUpdateReminderCoordinator.remindLater()", .laterAction),
        Mutation("store URL action", "openURL(update.storeURL)", .storeOpenAction),
        Mutation("store completion action", "appUpdateReminderCoordinator.didOpenStore()", .storeCompletionAction),
        Mutation(
            "locale argument",
            "LocaleAwareText.string(\"update.available.title\", locale: locale)",
            replacingWith: "LocaleAwareText.string(\"update.available.title\")",
            .localizedCopy
        ),
        Mutation("pending update gate", "appUpdateReminderCoordinator.pendingUpdate != nil", replacingWith: "true", .pendingUpdateGate),
        Mutation("backup reminder blocker", "!backupReminderPresenter.isPresented", replacingWith: "true", .backupReminderBlocker),
        Mutation("backup settings blocker", "!backupReminderPresenter.isShowingBackupSettings", replacingWith: "true", .backupSettingsBlocker),
        Mutation("inbox failure blocker", "patternInboxProcessor.failure == nil", replacingWith: "true", .inboxFailureBlocker),
        Mutation("inbox selection blocker", "patternInboxProcessor.pendingSelection == nil", replacingWith: "true", .inboxSelectionBlocker),
        Mutation("unlock sheet blocker", "!unlockSheetBinding.wrappedValue", replacingWith: "true", .unlockSheetBlocker),
        Mutation("active scene guard", "guard scenePhase == .active else { return }", .activeSceneGuard),
    ])
    func scopedContractRejectsEachMutationEvenWhenTheRemovedTokenExistsAsADecoy(
        _ mutation: Mutation
    ) throws {
        let source = try repositorySource("KnitNote/App/RootView.swift")
        let block = try updatePresentationBlock(in: source)
        let mutatedBlock = try #require(block.replacingFirstOccurrence(
            of: mutation.token,
            with: mutation.replacement
        ))
        let mutatedSource = source.replacingOccurrences(of: block, with: mutatedBlock)
            + "\n// out-of-owner decoy: \(mutation.token)\n"

        #expect(try updatePresentationFailures(in: mutatedSource) == [mutation.expectedFailure])
    }

    @Test func rootDeclaresSelectedLocaleOpenURLAndCoordinatorDependencies() throws {
        let source = try repositorySource("KnitNote/App/RootView.swift")

        #expect(source.contains("@Environment(\\.locale) private var locale"))
        #expect(source.contains("@Environment(\\.openURL) private var openURL"))
        #expect(source.contains("@EnvironmentObject private var appUpdateReminderCoordinator"))
    }
}

struct Mutation: Sendable, CustomTestStringConvertible {
    let name: String
    let token: String
    let replacement: String
    let expectedFailure: UpdatePresentationRequirement

    init(
        _ name: String,
        _ token: String,
        replacingWith replacement: String = "",
        _ expectedFailure: UpdatePresentationRequirement
    ) {
        self.name = name
        self.token = token
        self.replacement = replacement
        self.expectedFailure = expectedFailure
    }

    var testDescription: String { name }
}

enum UpdatePresentationRequirement: String, Hashable, Sendable {
    case localizedCopy
    case versionValues
    case laterAction
    case storeOpenAction
    case storeCompletionAction
    case pendingUpdateGate
    case backupReminderBlocker
    case backupSettingsBlocker
    case inboxFailureBlocker
    case inboxSelectionBlocker
    case unlockSheetBlocker
    case activeSceneGuard
    case activeSceneCheck
}

private func updatePresentationFailures(in source: String) throws -> Set<UpdatePresentationRequirement> {
    let block = try updatePresentationBlock(in: source)
    var failures = Set<UpdatePresentationRequirement>()
    let localizedExpressions = [
        "LocaleAwareText.string(\"update.available.title\", locale: locale)",
        "LocaleAwareText.string(\"update.available.currentVersion\", locale: locale)",
        "LocaleAwareText.string(\"update.available.latestVersion\", locale: locale)",
        "LocaleAwareText.format(\n                    \"update.available.message\",\n                    locale: locale,",
        "LocaleAwareText.string(\"update.available.later\", locale: locale)",
        "LocaleAwareText.string(\"update.available.openStore\", locale: locale)",
    ]
    if !localizedExpressions.allSatisfy(block.contains) || block.contains("A new version") || block.contains("有新版本") {
        failures.insert(.localizedCopy)
    }
    if !block.contains("AppVersionInfo.current()?.version") || !block.contains("update.displayVersion") {
        failures.insert(.versionValues)
    }
    if block.occurrences(of: "appUpdateReminderCoordinator.remindLater()") != 1 {
        failures.insert(.laterAction)
    }
    if block.occurrences(of: "openURL(update.storeURL)") != 1 {
        failures.insert(.storeOpenAction)
    }
    if block.occurrences(of: "appUpdateReminderCoordinator.didOpenStore()") != 1 {
        failures.insert(.storeCompletionAction)
    }
    let tokens: [(String, UpdatePresentationRequirement)] = [
        ("appUpdateReminderCoordinator.pendingUpdate != nil", .pendingUpdateGate),
        ("!backupReminderPresenter.isPresented", .backupReminderBlocker),
        ("!backupReminderPresenter.isShowingBackupSettings", .backupSettingsBlocker),
        ("patternInboxProcessor.failure == nil", .inboxFailureBlocker),
        ("patternInboxProcessor.pendingSelection == nil", .inboxSelectionBlocker),
        ("!unlockSheetBinding.wrappedValue", .unlockSheetBlocker),
        ("guard scenePhase == .active else { return }", .activeSceneGuard),
        ("await appUpdateReminderCoordinator.checkIfNeeded()", .activeSceneCheck),
    ]
    for (token, requirement) in tokens where !block.contains(token) {
        failures.insert(requirement)
    }
    return failures
}

private func updatePresentationBlock(in source: String) throws -> String {
    let startMarker = "// APP_UPDATE_PRESENTATION_BEGIN"
    let endMarker = "// APP_UPDATE_PRESENTATION_END"
    let startParts = source.components(separatedBy: startMarker)
    let endParts = source.components(separatedBy: endMarker)
    guard startParts.count == 2, endParts.count == 2,
          let start = source.range(of: startMarker)?.upperBound,
          let end = source.range(of: endMarker)?.lowerBound,
          start <= end else {
        throw UpdatePresentationContractError.missingUniqueOwnerMarkers
    }
    return String(source[start..<end])
}

private enum UpdatePresentationContractError: Error {
    case missingUniqueOwnerMarkers
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }

    func replacingFirstOccurrence(of needle: String, with replacement: String) -> String? {
        guard let range = range(of: needle) else { return nil }
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}

private func repositorySource(_ relativePath: String) throws -> String {
    try String(contentsOf: updateReminderRepositoryRoot.appending(path: relativePath), encoding: .utf8)
}

private let updateReminderRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
