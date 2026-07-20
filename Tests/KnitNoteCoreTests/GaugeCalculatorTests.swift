import Testing
@testable import KnitNoteCore

@Suite struct GaugeCalculatorTests {
    @Test func calculatesStitchesAndRoundsHalfUp() throws {
        let result = try #require(GaugeCalculator.calculate(
            GaugeInput(sampleLength: 10, sampleCount: 19, targetLength: 43)
        ))
        #expect(result.density == 1.9)
        #expect(abs(result.exactCount - 81.7) < 0.000_001)
        #expect(result.recommendedCount == 82)
    }

    @Test func roundsHalfUpAtAnExactTie() throws {
        let result = try #require(GaugeCalculator.calculate(
            GaugeInput(sampleLength: 2, sampleCount: 169, targetLength: 1)
        ))

        #expect(result.exactCount == 84.5)
        #expect(result.recommendedCount == 85)
    }

    @Test func rejectsNonPositiveAndNonFiniteInputs() {
        #expect(GaugeCalculator.calculate(.init(sampleLength: 0, sampleCount: 20, targetLength: 40)) == nil)
        #expect(GaugeCalculator.calculate(.init(sampleLength: 10, sampleCount: .infinity, targetLength: 40)) == nil)
    }

    @Test func rejectsCountsThatRoundOutsideTheIntRange() {
        let input = GaugeInput(
            sampleLength: 1,
            sampleCount: Double(Int.max),
            targetLength: 1
        )

        #expect(GaugeCalculator.calculate(input) == nil)
    }

    @Test func convertsLengthWithoutChangingCounts() {
        #expect(abs(GaugeCalculator.convertLength(10, from: .centimeters, to: .inches) - 3.937_007_874) < 0.000_001)
        #expect(abs(GaugeCalculator.convertLength(4, from: .inches, to: .centimeters) - 10.16) < 0.000_001)
    }

    @Test func fieldValidationOnlyFlagsInvalidValuesAfterTheGroupStarts() {
        #expect(!GaugeCalculator.fieldNeedsValidation(nil, groupStarted: false))
        #expect(!GaugeCalculator.fieldNeedsValidation(0, groupStarted: false))
        #expect(!GaugeCalculator.fieldNeedsValidation(.infinity, groupStarted: false))

        #expect(GaugeCalculator.fieldNeedsValidation(nil, groupStarted: true))
        #expect(GaugeCalculator.fieldNeedsValidation(0, groupStarted: true))
        #expect(GaugeCalculator.fieldNeedsValidation(-1, groupStarted: true))
        #expect(GaugeCalculator.fieldNeedsValidation(.infinity, groupStarted: true))
        #expect(GaugeCalculator.fieldNeedsValidation(.nan, groupStarted: true))
        #expect(!GaugeCalculator.fieldNeedsValidation(0.1, groupStarted: true))
    }
}
