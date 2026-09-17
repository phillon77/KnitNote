import XCTest
@testable import KnittingCalculator

final class CalculatorAdSessionTests: XCTestCase {
    func testInterruptedPresentationCanResumeWithoutRepeatingConsentRequest() {
        var session = CalculatorAdSession()
        XCTAssertFalse(session.needsConsentPresentation)
        XCTAssertTrue(session.beginConsentUpdate())
        // Leaving home must not mark the still-unpresented form as completed.
        XCTAssertTrue(session.needsConsentPresentation)
        XCTAssertFalse(session.beginConsentUpdate())
        XCTAssertTrue(session.needsConsentPresentation)
        session.completeConsentUpdate(canRequestAds: true)
        XCTAssertFalse(session.needsConsentPresentation)
        XCTAssertTrue(session.canRequestAds)
    }
    func testAdsStayDisabledUntilCurrentConsentCompletes() {
        var session = CalculatorAdSession()
        XCTAssertFalse(session.canRequestAds)
        XCTAssertFalse(session.claimSDKInitialization())
        XCTAssertTrue(session.beginConsentUpdate())
        XCTAssertFalse(session.beginConsentUpdate())
        XCTAssertFalse(session.canRequestAds)
        session.completeConsentUpdate(canRequestAds: true)
        XCTAssertTrue(session.canRequestAds)
        XCTAssertTrue(session.claimSDKInitialization())
        XCTAssertFalse(session.claimSDKInitialization())
    }

    func testConsentFailureLeavesAdsDisabledAndDoesNotLoop() {
        var session = CalculatorAdSession()
        XCTAssertTrue(session.beginConsentUpdate())
        session.completeConsentUpdate(canRequestAds: false)
        XCTAssertFalse(session.canRequestAds)
        XCTAssertFalse(session.claimSDKInitialization())
        XCTAssertFalse(session.beginConsentUpdate())
    }

    func testPrivacyChangeImmediatelyStopsRequestsAndRespectsNewChoice() {
        var session = CalculatorAdSession()
        _ = session.beginConsentUpdate()
        session.completeConsentUpdate(canRequestAds: true)
        XCTAssertTrue(session.claimSDKInitialization())
        session.beginPrivacyUpdate()
        XCTAssertFalse(session.canRequestAds)
        session.completeConsentUpdate(canRequestAds: false)
        XCTAssertFalse(session.canRequestAds)
        session.beginPrivacyUpdate()
        session.completeConsentUpdate(canRequestAds: true)
        XCTAssertTrue(session.canRequestAds)
        XCTAssertFalse(session.claimSDKInitialization())
    }
}
