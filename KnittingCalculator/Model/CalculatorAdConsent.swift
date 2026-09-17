import SwiftUI
@preconcurrency import GoogleMobileAds
@preconcurrency import UserMessagingPlatform

@MainActor
final class CalculatorAdConsent: ObservableObject {
    let configuration: CalculatorAdConfiguration
    @Published private(set) var canRequestAds = false
    @Published private(set) var requiresPrivacyOptions = false
    @Published private(set) var isUpdatingPrivacy = false
    @Published var showsPrivacyError = false
    private var session = CalculatorAdSession()
    private var consentInfoTask: Task<Bool, Never>?
    private var consentFormTask: Task<ConsentForm?, Never>?
    private var isPresentingConsent = false

    init(configuration: CalculatorAdConfiguration = .current) {
        self.configuration = configuration
    }

    func prepare(from presenter: UIViewController) async {
        guard configuration != .disabled else { return }
        if consentInfoTask == nil, session.beginConsentUpdate() {
            // The network update belongs to the app session, not a transient home view.
            consentInfoTask = Task {
                do {
                    let parameters = RequestParameters()
#if DEBUG
                    // Explicit QA only: the device identifier comes from UMP's diagnostic
                    // output and is supplied at launch, never committed into the app.
                    if configuration == .test,
                       ProcessInfo.processInfo.arguments.contains("-calculatorConsentTest"),
                       let deviceID = ProcessInfo.processInfo.environment["CALCULATOR_UMP_TEST_DEVICE"],
                       !deviceID.isEmpty {
                        let debug = DebugSettings()
                        debug.testDeviceIdentifiers = [deviceID]
                        debug.geography = .EEA
                        parameters.debugSettings = debug
                        if ProcessInfo.processInfo.arguments.contains("-calculatorResetConsent") {
                            ConsentInformation.shared.reset()
                        }
                        print("[CalculatorConsentQA] requesting EEA test consent")
                    }
#endif
                    try await ConsentInformation.shared.requestConsentInfoUpdate(with: parameters)
#if DEBUG
                    print("[CalculatorConsentQA] status=\(ConsentInformation.shared.consentStatus.rawValue), eligible=\(ConsentInformation.shared.canRequestAds), privacyOptions=\(ConsentInformation.shared.privacyOptionsRequirementStatus.rawValue)")
#endif
                    return true
                } catch {
#if DEBUG
                    print("[CalculatorConsentQA] update failed: \(error)")
#endif
                    return false
                }
            }
        }
        guard let consentInfoTask else { return }
        let didUpdate = await consentInfoTask.value
        requiresPrivacyOptions = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        guard didUpdate else {
            session.completeConsentUpdate(canRequestAds: false)
            return
        }
        // Interrupted navigation leaves presentation pending for the next active home view.
        guard !Task.isCancelled, presenter.viewIfLoaded?.window != nil,
              session.needsConsentPresentation else { return }
        guard ConsentInformation.shared.consentStatus == .required else {
            await updateEligibility()
            return
        }
        if consentFormTask == nil {
            consentFormTask = Task {
                try? await ConsentForm.load()
            }
        }
        guard let consentFormTask else { return }
        let form = await consentFormTask.value
        guard !Task.isCancelled, presenter.viewIfLoaded?.window != nil,
              session.needsConsentPresentation, !isPresentingConsent else { return }
        guard let form else {
            session.completeConsentUpdate(canRequestAds: false)
            return
        }
        // Loading is independent of the old controller. Present only after confirming
        // the current controller is attached, and never present the single-use form twice.
        isPresentingConsent = true
        defer { isPresentingConsent = false }
        do {
            try await form.present(from: presenter)
#if DEBUG
            print("[CalculatorConsentQA] form dismissed; eligible=\(ConsentInformation.shared.canRequestAds)")
#endif
            await updateEligibility()
        } catch {
            if Task.isCancelled || presenter.viewIfLoaded?.window == nil {
                self.consentFormTask = nil
            } else {
                session.completeConsentUpdate(canRequestAds: false)
            }
        }
    }

    func showPrivacyOptions() async {
        guard requiresPrivacyOptions, !isUpdatingPrivacy else { return }
        isUpdatingPrivacy = true
        session.beginPrivacyUpdate()
        canRequestAds = false
        defer { isUpdatingPrivacy = false }
        do {
            try await ConsentForm.presentPrivacyOptionsForm(from: nil)
#if DEBUG
            print("[CalculatorConsentQA] privacy options dismissed; eligible=\(ConsentInformation.shared.canRequestAds)")
#endif
            await updateEligibility()
        } catch {
            // No ad reload after an unsuccessful change; let the user retry explicitly.
            showsPrivacyError = true
        }
    }

    private func updateEligibility() async {
        requiresPrivacyOptions = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        session.completeConsentUpdate(canRequestAds: ConsentInformation.shared.canRequestAds)
        if session.claimSDKInitialization() {
            let configuration = MobileAds.shared.requestConfiguration
            configuration.publisherPrivacyPersonalizationState = .disabled
            configuration.setPublisherFirstPartyIDEnabled(false)
            configuration.maxAdContentRating = .general
            // Video must be disabled in the AdMob unit. Banner video starts muted by
            // Google's policy; don't misuse the global mute API without user volume controls.
            await MobileAds.shared.start()
        }
        canRequestAds = session.canRequestAds
    }
}
