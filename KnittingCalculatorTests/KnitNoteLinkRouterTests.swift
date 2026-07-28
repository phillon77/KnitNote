import XCTest
@testable import KnittingCalculator

final class KnitNoteLinkRouterTests: XCTestCase {
    func testUsesFinishedDestinationWhenKnitNoteLaunchSucceeds() {
        XCTAssertEqual(KnitNoteLinkRouter.destination(after: true), .finished)
    }

    func testUsesAppStoreWhenKnitNoteLaunchFails() {
        XCTAssertEqual(
            KnitNoteLinkRouter.destination(after: false),
            .openStore(URL(string: "https://apps.apple.com/app/id6793023054")!)
        )
    }
}
