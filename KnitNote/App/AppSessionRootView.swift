import SwiftUI

/// The identity covers all content, sheets and presentation state, while
/// App-global entitlement and locale are inherited from outside this boundary.
struct AppSessionRootView<Content: View, Unavailable: View>: View {
    @ObservedObject var owner: AppSessionOwner
    @ViewBuilder let content: () -> Content
    @ViewBuilder let unavailable: () -> Unavailable

    var body: some View {
        Group {
            if let session = owner.visibleSession, let presentation = session.presentation {
                content()
                    .environmentObject(session.store)
                    .environmentObject(presentation.patternInboxProcessor)
                    .environmentObject(presentation.patternBackupReminderPresenter)
                    .environmentObject(presentation.reminderPresentationStore)
                    .id(session.id)
            } else {
                unavailable()
            }
        }
    }
}
