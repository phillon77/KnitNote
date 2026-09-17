/// Owns session eligibility independently of network SDK callbacks.
struct CalculatorAdSession {
    private(set) var canRequestAds = false
    private var hasRequestedConsent = false
    private var hasStartedSDK = false
    private var hasCompletedConsent = false

    var needsConsentPresentation: Bool { hasRequestedConsent && !hasCompletedConsent }

    mutating func beginConsentUpdate() -> Bool {
        guard !hasRequestedConsent else { return false }
        hasRequestedConsent = true
        canRequestAds = false
        return true
    }

    mutating func completeConsentUpdate(canRequestAds: Bool) {
        hasCompletedConsent = true
        self.canRequestAds = canRequestAds
    }

    mutating func beginPrivacyUpdate() {
        canRequestAds = false
    }

    mutating func claimSDKInitialization() -> Bool {
        guard canRequestAds, !hasStartedSDK else { return false }
        hasStartedSDK = true
        return true
    }
}
