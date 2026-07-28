import XCTest
@testable import KnittingCalculator

final class TargetSmokeTests: XCTestCase {
    func testSharedGaugeCoreIsLinked() {
        let result = GaugeCalculator.calculate(
            .init(sampleLength: 10, sampleCount: 20, targetLength: 40)
        )
        XCTAssertEqual(result?.recommendedCount, 80)
    }
}
