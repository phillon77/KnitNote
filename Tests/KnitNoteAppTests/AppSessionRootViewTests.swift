#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import KnitNote

@MainActor
@Suite(.serialized) struct AppSessionRootViewTests {
    // The same production boundary serves two independently hosted windows.
    // Removing an injection, the unavailable branch or identity breaks this.
    @Test func windowsShareFixedResourcesAndTransitionRemovesOldContent() async throws {
        try await withCompositionFixture { fixture in
            let a = try fixture.makeSession(withWatch: false)
            let b = try fixture.makeSession(withWatch: false)
            let owner = AppSessionOwner()
            try owner.publishPreparedSession(a, for: owner.generation)
            let shared = RootSharedPreferences()
            let first = RootHost(owner: owner, shared: shared)
            let second = RootHost(owner: owner, shared: shared)
            defer { first.close(); second.close() }
            first.render { first.probe.snapshot?.store === a.store }
            second.render { second.probe.snapshot?.store === a.store }
            let firstA = try #require(first.probe.snapshot)
            let secondA = try #require(second.probe.snapshot)
            #expect(firstA.inbox === a.presentation?.patternInboxProcessor)
            #expect(firstA.backup === a.presentation?.patternBackupReminderPresenter)
            #expect(firstA.reminders === a.presentation?.reminderPresentationStore)
            #expect(firstA.inbox === secondA.inbox)
            #expect(firstA.backup === secondA.backup)
            #expect(firstA.reminders === secondA.reminders)
            let oldMutation = firstA.mutateStore
            let generation = owner.beginTransition()
            first.render { first.probe.unavailable && first.probe.activeContent == 0 }
            second.render { second.probe.unavailable && second.probe.activeContent == 0 }
            #expect(first.probe.unavailable && first.probe.activeContent == 0)
            #expect(second.probe.unavailable && second.probe.activeContent == 0)
            try await owner.waitForRetiredSessions()
            try owner.publishPreparedSession(b, for: generation)
            first.render { first.probe.snapshot?.store === b.store && first.probe.activeContent == 1 }
            second.render { second.probe.snapshot?.store === b.store }
            #expect(first.probe.snapshot?.inbox === b.presentation?.patternInboxProcessor)
            #expect(second.probe.snapshot?.inbox === b.presentation?.patternInboxProcessor)
            #expect(throws: StoreSessionAccessError.revoked) { try oldMutation() }
            #expect(b.store.projects.isEmpty)
        }
    }

    // A nil transition need not render before B arrives. Only .id around the
    // entire session subtree resets these @State values for coincident IDs.
    @Test func replacementResetsSelectionAndPreviewWithoutAnIntermediateFrame() async throws {
        try await withCompositionFixture { fixture in
            let directoryA = fixture.root.appending(path: "A")
            let directoryB = fixture.root.appending(path: "B")
            let a = try fixture.makeSession(store: fixture.makeStore(at: directoryA), withWatch: false)
            try a.store.add(name: "Same project")
            // Same archive gives both stores precisely the same project UUID.
            try FileManager.default.createDirectory(at: directoryB.appending(path: "KnitNote"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: directoryA.appending(path: "KnitNote/projects-v1.json"),
                                             to: directoryB.appending(path: "KnitNote/projects-v1.json"))
            let b = try fixture.makeSession(store: fixture.makeStore(at: directoryB), withWatch: false)
            let projectID = try #require(a.store.projects.first?.id)
            #expect(b.store.projects.first?.id == projectID)
            let owner = AppSessionOwner()
            try owner.publishPreparedSession(a, for: owner.generation)
            let shared = RootSharedPreferences()
            let host = RootHost(owner: owner, shared: shared)
            defer { host.close() }
            host.render { host.probe.snapshot?.store === a.store }
            let first = try #require(host.probe.snapshot)
            first.selectAndPreview()
            host.render { host.probe.snapshot?.selection != nil && host.probe.snapshot?.preview == true }
            #expect(host.probe.snapshot?.selection == projectID)
            #expect(host.probe.snapshot?.preview == true)
            let generation = owner.beginTransition()
            try await owner.waitForRetiredSessions()
            try owner.publishPreparedSession(b, for: generation)
            host.render { host.probe.snapshot?.store === b.store }
            let replacement = try #require(host.probe.snapshot)
            #expect(replacement.store === b.store)
            #expect(replacement.stateID != first.stateID)
            #expect(replacement.selection == nil)
            #expect(!replacement.preview)
            replacement.selectAndPreview()
            host.render { host.probe.snapshot?.preview == true }
            shared.language = "fr"
            #expect(shared.entitlement.verifiedSnapshot == nil)
            await shared.entitlement.prepare()
            #expect(shared.entitlement.verifiedSnapshot != nil)
            host.render { host.probe.snapshot?.locale == "fr" }
            #expect(host.probe.snapshot?.stateID == replacement.stateID)
            #expect(host.probe.snapshot?.selection == projectID)
            #expect(host.probe.snapshot?.preview == true)
            #expect(host.probe.snapshot?.entitlement === shared.entitlement)
        }
    }

    @Test func missingPresentationShowsUnavailableInsteadOfSubstituteObjects() async throws {
        try await withCompositionFixture { fixture in
            let owner = AppSessionOwner()
            let incomplete = try AppSessionResources(store: fixture.makeStore()) { _ in [] }
            try owner.publishPreparedSession(incomplete, for: owner.generation)
            let host = RootHost(owner: owner, shared: RootSharedPreferences())
            defer { host.close() }
            host.render { host.probe.unavailable }
            #expect(host.probe.unavailable)
            #expect(host.probe.activeContent == 0)
            _ = owner.beginTransition()
            try await owner.waitForRetiredSessions()
        }
    }
}

@MainActor private final class RootSharedPreferences: ObservableObject {
    @Published var language = "en"
    let entitlement = EntitlementCoordinator(
        purchaseService: ProducerTestTrialPurchaseService(),
        trialStore: ProducerTestFixedTrialStore(record: TrialRecord(startedAt: Date()))
    )
}

@MainActor private final class RootProbe {
    struct Snapshot {
        let store: JSONProjectStore
        let inbox: PatternInboxProcessor
        let backup: PatternBackupReminderPresenter
        let reminders: KnittingReminderPresentationStore
        let entitlement: EntitlementCoordinator
        let locale: String
        let stateID: UUID
        let selection: UUID?
        let preview: Bool
        let selectAndPreview: () -> Void
        let mutateStore: () throws -> Void
    }
    var snapshot: Snapshot?
    var activeContent = 0
    var unavailable = false
}

private struct RootContent: View {
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var inbox: PatternInboxProcessor
    @EnvironmentObject private var backup: PatternBackupReminderPresenter
    @EnvironmentObject private var reminders: KnittingReminderPresentationStore
    @EnvironmentObject private var entitlement: EntitlementCoordinator
    @Environment(\.locale) private var locale
    @State private var stateID = UUID()
    @State private var selection: UUID?
    @State private var preview = false
    let probe: RootProbe

    var body: some View {
        RootProbeView(probe: probe, snapshot: RootProbe.Snapshot(
            store: store, inbox: inbox, backup: backup, reminders: reminders,
            entitlement: entitlement, locale: locale.identifier,
            stateID: stateID, selection: selection, preview: preview,
            selectAndPreview: { selection = store.projects.first?.id; preview = true },
            mutateStore: { [store] in try store.add(name: "Old closure") }
        ))
    }
}

private struct RootProbeView: NSViewRepresentable {
    let probe: RootProbe
    let snapshot: RootProbe.Snapshot
    func makeCoordinator() -> RootProbe { probe }
    func makeNSView(context: Context) -> NSView {
        probe.activeContent += 1
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        probe.snapshot = snapshot
        probe.unavailable = false
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: RootProbe) {
        coordinator.activeContent -= 1
    }
}

private struct RootHostContent: View {
    let owner: AppSessionOwner
    @ObservedObject var shared: RootSharedPreferences
    let probe: RootProbe
    var body: some View {
        AppSessionRootView(owner: owner) {
            RootContent(probe: probe)
        } unavailable: {
            Color.clear.onAppear { probe.unavailable = true }
        }
        .environmentObject(shared.entitlement)
        .environment(\.locale, Locale(identifier: shared.language))
    }
}

@MainActor private final class RootHost {
    let probe = RootProbe()
    let host: NSHostingView<AnyView>
    let window: NSWindow
    init(owner: AppSessionOwner, shared: RootSharedPreferences) {
        host = NSHostingView(rootView: AnyView(RootHostContent(owner: owner, shared: shared, probe: probe)))
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
    }
    func render(until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while !predicate() && Date() < deadline
        #expect(predicate())
    }
    func close() {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}
#endif
