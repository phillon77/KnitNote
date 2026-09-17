import SwiftUI
@preconcurrency import GoogleMobileAds

struct CalculatorBannerPlacement: View {
    @EnvironmentObject private var advertising: CalculatorAdConsent
    @Environment(\.scenePhase) private var scenePhase
    @State private var availableWidth: CGFloat = 0
    @State private var isLoaded = false
    let isHomeVisible: Bool

    private var isPreview: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-calculatorBannerPreview")
            && !ProcessInfo.processInfo.arguments.contains("-storeScreenshotMode")
#else
        false
#endif
    }

    private var isActive: Bool {
        isHomeVisible && scenePhase == .active && availableWidth >= 344
    }

    var body: some View {
        VStack(spacing: 6) {
            if isActive && (isPreview || advertising.configuration != .disabled) {
                Text("calculator.advertising.label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isPreview {
#if DEBUG
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CalculatorTheme.blush.opacity(0.6))
                        .overlay {
                            Text("calculator.advertising.preview")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 320, height: 50)
#endif
                } else {
                    CalculatorBannerHost(advertising: advertising, isLoaded: $isLoaded)
                        .frame(width: 320, height: 50)
                }
            }
        }
        .padding(.vertical, isActive && (isPreview || isLoaded) ? 10 : 0)
        .frame(maxWidth: .infinity)
        .frame(height: isActive && (isPreview || isLoaded) ? nil : 0)
        .clipped()
        .accessibilityHidden(!(isActive && (isPreview || isLoaded)))
        .background(.background)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onChange(of: isActive) { _, active in
            if !active { isLoaded = false }
        }
        .accessibilityIdentifier("calculator.advertising.placement")
    }
}

private struct CalculatorBannerHost: UIViewControllerRepresentable {
    @ObservedObject var advertising: CalculatorAdConsent
    @Binding var isLoaded: Bool

    func makeUIViewController(context: Context) -> CalculatorBannerController {
        let controller = CalculatorBannerController(advertising: advertising)
        controller.onLoadChange = { value in
            // Delegate callbacks must not mutate SwiftUI state during an update pass.
            Task { @MainActor in isLoaded = value }
        }
        return controller
    }

    func updateUIViewController(_ controller: CalculatorBannerController, context: Context) {
        controller.updateEligibility()
    }

    static func dismantleUIViewController(_ controller: CalculatorBannerController, coordinator: ()) {
        controller.stop()
    }
}

@MainActor
private final class CalculatorBannerController: UIViewController, BannerViewDelegate {
    let advertising: CalculatorAdConsent
    var onLoadChange: ((Bool) -> Void)?
    private var banner: BannerView?
    private var didRequest = false
    private var isVisible = false
    private var preparation: Task<Void, Never>?

    init(advertising: CalculatorAdConsent) {
        self.advertising = advertising
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(advertising:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        preparation = Task { [weak self] in
            guard let self else { return }
            await advertising.prepare(from: self)
            guard !Task.isCancelled else { return }
            updateEligibility()
        }
    }

    func updateEligibility() {
        guard advertising.canRequestAds else {
            removeBanner()
            return
        }
        guard isVisible, viewIfLoaded?.window != nil, !didRequest,
              let unitID = advertising.configuration.bannerUnitID else { return }
        didRequest = true
        let banner = BannerView(adSize: AdSizeBanner)
        self.banner = banner
        banner.adUnitID = unitID
        banner.rootViewController = self
        banner.delegate = self
        // Never supply collapsible extras, content URLs, user IDs, or calculator inputs.
        banner.load(Request())
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        guard bannerView === banner, isVisible, advertising.canRequestAds else { return }
        guard !bannerView.isCollapsible else {
            removeBanner()
            didRequest = true
            return
        }
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        if bannerView.superview == nil {
            view.addSubview(bannerView)
            NSLayoutConstraint.activate([
                bannerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                bannerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                bannerView.widthAnchor.constraint(equalToConstant: 320),
                bannerView.heightAnchor.constraint(equalToConstant: 50),
            ])
        }
        onLoadChange?(true)
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        guard bannerView === banner else { return }
        removeBanner()
        didRequest = true // No automatic retry loop on a failed request.
    }

    func stop() {
        isVisible = false
        preparation?.cancel()
        preparation = nil
        onLoadChange = nil
        removeBanner()
    }

    private func removeBanner() {
        let hadBanner = banner != nil
        banner?.delegate = nil
        banner?.removeFromSuperview()
        banner = nil
        didRequest = false
        if hadBanner { onLoadChange?(false) }
    }
}
