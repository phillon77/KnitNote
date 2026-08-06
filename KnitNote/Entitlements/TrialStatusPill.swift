import SwiftUI

struct TrialStatusPill: View {
    @Environment(\.locale) private var locale
    let snapshot: EntitlementSnapshot
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let expiresAt = UnlockPresentation.activeTrialExpiry(
                snapshot: snapshot,
                now: context.date
            ) {
                let remainingDays = UnlockPresentation.remainingDays(
                    now: context.date,
                    expiresAt: expiresAt
                )
                let accessibilityCopy = if remainingDays == 1 {
                    LocaleAwareText.string(
                        "unlock.trial.accessibility.one",
                        locale: locale
                    )
                } else {
                    LocaleAwareText.format(
                        "unlock.trial.accessibility.many.format",
                        locale: locale,
                        remainingDays
                    )
                }
                Button(action: action) {
                    Label {
                        if remainingDays == 1 {
                            Text("unlock.trial.active.one")
                        } else {
                            Text(
                                LocaleAwareText.format(
                                    "unlock.trial.active.many.format",
                                    locale: locale,
                                    remainingDays
                                )
                            )
                        }
                    } icon: {
                        Image(systemName: "clock.badge.checkmark")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(WatercolorTheme.actionBerry)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        WatercolorTheme.softWhite.opacity(0.94),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                WatercolorTheme.actionBerry.opacity(0.24),
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(accessibilityCopy))
            }
        }
    }
}
