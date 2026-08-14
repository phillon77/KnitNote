import Foundation
import StoreKit
#if os(iOS)
import UIKit
#endif

enum AppUpdateReminderLiveFactory {
    @MainActor
    static func make(fixture: AppUpdateFixture?) -> AppUpdateReminderCoordinator {
        let platform: AppStorePlatform
#if os(macOS)
        platform = .macOS
#else
        platform = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
#endif
        let lookup = AppStoreUpdateLookup.live()
        return AppUpdateReminderCoordinator(
            enabled: true,
            installedVersion: { AppVersionInfo.current()?.version },
            platform: platform,
            countryCode: {
                guard fixture == nil else { return "tw" }
                let storefrontCode = await Storefront.current?.countryCode
                let alpha2 = storefrontCode.flatMap {
                    Locale(identifier: "en_\($0)").region?.identifier
                }
                return AppStoreUpdateLookup.normalizedCountryCode(alpha2)
                    ?? AppStoreUpdateLookup.normalizedCountryCode(Locale.current.region?.identifier)
                    ?? "tw"
            },
            fetch: { countryCode, platform in
                if let fixture {
                    return fixture.availableUpdate
                }
                return await lookup.fetch(countryCode: countryCode, platform: platform)
            },
            history: UpdateReminderHistory()
        )
    }
}
