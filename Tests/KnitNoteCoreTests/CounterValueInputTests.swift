import Testing
@testable import KnitNoteCore

@Suite struct CounterValueInputTests {
    @Test(arguments: ["", "-1", "1.5", "abc", "999999999999999999999999"])
    func invalidCounterDraftsAreRejected(_ text: String) {
        #expect(throws: CounterValueInputError.self) {
            try CounterValueInput.parse(text)
        }
    }

    @Test func validCounterDraftUsesTheWholeNumber() throws {
        #expect(try CounterValueInput.parse("2048") == 2048)
    }

    @Test(arguments: ["+1", "١", "１２"])
    func nonDecimalDraftsAreRejected(_ text: String) {
        #expect(throws: CounterValueInputError.self) {
            try CounterValueInput.parse(text)
        }
    }
}
