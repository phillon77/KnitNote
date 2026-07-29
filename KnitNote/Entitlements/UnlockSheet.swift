import StoreKit
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct UnlockSheet: View {
    private enum Notice: Equatable {
        case pending
        case cancelled
        case restoreNotFound
        case redeemUnavailable
        case retry

        var localizationKey: LocalizedStringKey {
            switch self {
            case .pending:
                "unlock.pending"
            case .cancelled:
                "unlock.cancelled"
            case .restoreNotFound:
                "unlock.restore.notFound"
            case .redeemUnavailable:
                "unlock.redeem.unavailable"
            case .retry:
                "unlock.retry"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var coordinator: EntitlementCoordinator
    @State private var isBusy = false
    @State private var notice: Notice?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(WatercolorTheme.actionBerry)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("unlock.title")
                            .font(.title2.bold())
                            .foregroundStyle(WatercolorTheme.ink)

                        Text(primaryMessageKey)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)

                        if isTrialExpired {
                            Text(
                                LocalizedStringKey(
                                    UnlockPresentation.expiredMessageKey
                                )
                            )
                                .font(.callout.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(WatercolorTheme.actionBerry)

                            Text("unlock.readOnly")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let notice {
                        Label(notice.localizationKey, systemImage: noticeIcon)
                            .font(.callout)
                            .foregroundStyle(WatercolorTheme.actionBerry)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button {
                            runPurchase()
                        } label: {
                            purchaseLabel
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WatercolorTheme.actionBerry)
                        .disabled(isBusy)
                        .accessibilityLabel(purchaseAccessibilityLabel)

                        Button("unlock.restore") {
                            runRestore()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                        .accessibilityLabel(Text("unlock.accessibility.restore"))

                        Button("unlock.redeem") {
                            runRedemption()
                        }
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                        .accessibilityLabel(Text("unlock.accessibility.redeem"))
                    }
                    .controlSize(.large)

                    Text("unlock.watch.guidance")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 520)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(WatercolorBackground())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        close()
                    }
                    .disabled(isBusy)
                    .accessibilityLabel(Text("unlock.accessibility.dismiss"))
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private var primaryMessageKey: LocalizedStringKey {
        "unlock.lifetime.message"
    }

    private var isTrialExpired: Bool {
        coordinator.snapshot.state(at: .now) == .trialExpired
    }

    private var noticeIcon: String {
        notice == .retry ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }

    @ViewBuilder
    private var purchaseLabel: some View {
        if isBusy {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if let price = coordinator.localizedLifetimePrice {
            Text(
                String.localizedStringWithFormat(
                    String(
                        localized: "unlock.purchase.format",
                        locale: locale
                    ),
                    price
                )
            )
            .frame(maxWidth: .infinity)
        } else {
            Text("unlock.purchase.unavailable")
                .frame(maxWidth: .infinity)
        }
    }

    private var purchaseAccessibilityLabel: Text {
        if let price = coordinator.localizedLifetimePrice {
            Text(
                String.localizedStringWithFormat(
                    String(
                        localized: "unlock.accessibility.purchase.format",
                        locale: locale
                    ),
                    price
                )
            )
        } else {
            Text("unlock.accessibility.purchase")
        }
    }

    private func runPurchase() {
        guard !isBusy else { return }
        isBusy = true
        notice = nil
        Task {
            defer { isBusy = false }
            do {
                switch try await coordinator.purchaseLifetime() {
                case .purchased:
                    closeIfQualified()
                case .pending:
                    notice = .pending
                case .cancelled:
                    notice = .cancelled
                }
            } catch {
                notice = .retry
            }
        }
    }

    private func runRestore() {
        guard !isBusy else { return }
        isBusy = true
        notice = nil
        Task {
            defer { isBusy = false }
            do {
                let qualification = try await coordinator.restorePurchases()
                switch UnlockPresentation.restorePresentation(
                    for: qualification
                ) {
                case .close:
                    closeIfQualified()
                case .restoreNotFound:
                    notice = .restoreNotFound
                case .retry:
                    notice = .retry
                }
            } catch {
                notice = .retry
            }
        }
    }

    private func runRedemption() {
        guard !isBusy else { return }
        isBusy = true
        notice = nil
        Task {
            defer { isBusy = false }
            #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            else {
                notice = .redeemUnavailable
                return
            }
            do {
                try await AppStore.presentOfferCodeRedeemSheet(in: scene)
                await coordinator.refreshEntitlement()
                if !closeIfQualified() {
                    notice = .restoreNotFound
                }
            } catch {
                notice = .retry
            }
            #elseif os(macOS)
            guard let controller = NSApplication.shared.keyWindow?
                .contentViewController
                ?? NSApplication.shared.windows
                    .first(where: \.isVisible)?
                    .contentViewController
            else {
                notice = .redeemUnavailable
                return
            }
            do {
                try await AppStore.presentOfferCodeRedeemSheet(
                    from: controller
                )
                await coordinator.refreshEntitlement()
                if !closeIfQualified() {
                    notice = .restoreNotFound
                }
            } catch {
                notice = .retry
            }
            #else
            notice = .redeemUnavailable
            #endif
        }
    }

    @discardableResult
    private func closeIfQualified() -> Bool {
        switch coordinator.snapshot.state(at: .now) {
        case .permanentlyUnlocked, .legacyPaidOwner:
            close()
            return true
        case .trialNotStarted, .trialActive, .trialExpired:
            return false
        }
    }

    private func close() {
        coordinator.dismissUnlock()
        dismiss()
    }
}
