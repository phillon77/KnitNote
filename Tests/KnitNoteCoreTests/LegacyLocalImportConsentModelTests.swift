import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct LegacyLocalImportConsentModelTests {
    private func observation() -> LegacyLocalImportObservation {
        .init(source: .availableLocalHistoryUnknown,
              sourceDigest: Data(repeating: 1, count: 32),
              backupDigest: Data(repeating: 2, count: 32),
              accountDigest: Data(repeating: 3, count: 32),
              sourceSession: UUID(), targetSession: UUID(), preparation: UUID())
    }

    @Test func oneShotAndNoAutomaticAcceptance() throws {
        let model = LegacyLocalImportConsentModel()
        let current = observation()
        #expect(model.state == .idle)
        let proposal = try #require(model.present(current))
        #expect(model.state == .awaitingConfirmation)
        #expect(model.confirm(proposal, current: current))
        #expect(model.state == .confirmedIntentOnly)
        #expect(!model.confirm(proposal, current: current))
    }

    @Test func foreignOwnerAndStaleProposalCannotConfirm() throws {
        let a = LegacyLocalImportConsentModel()
        let b = LegacyLocalImportConsentModel()
        let current = observation()
        let old = try #require(a.present(current))
        let fresh = try #require(b.present(current))
        #expect(!b.confirm(old, current: current))
        #expect(b.confirm(fresh, current: current))
        a.invalidate()
        #expect(!a.confirm(old, current: current))
    }

    @Test func everyChangedBindingInvalidates() throws {
        for field in 0..<7 {
            let model = LegacyLocalImportConsentModel()
            let current = observation()
            let proposal = try #require(model.present(current))
            var changed = current
            switch field {
            case 0: changed.source = .foreignAccount
            case 1: changed.sourceDigest = Data(repeating: 8, count: 32)
            case 2: changed.backupDigest = Data(repeating: 8, count: 32)
            case 3: changed.accountDigest = Data(repeating: 8, count: 32)
            case 4: changed.sourceSession = UUID()
            case 5: changed.targetSession = UUID()
            default: changed.preparation = UUID()
            }
            #expect(!model.confirm(proposal, current: changed))
            #expect(model.state == .invalidated)
            #expect(!model.confirm(proposal, current: current))
        }
    }

    @Test func blockedAndMalformedNeverPresent() {
        for source in LegacyLocalImportSource.allCases {
            var value = observation(); value.source = source
            let model = LegacyLocalImportConsentModel()
            #expect((model.present(value) != nil) == (source == .availableLocalHistoryUnknown))
        }
        for length in [0, 31, 33] {
            for field in 0..<3 {
                var value = observation()
                switch field {
                case 0: value.sourceDigest = Data(repeating: 0, count: length)
                case 1: value.backupDigest = Data(repeating: 0, count: length)
                default: value.accountDigest = Data(repeating: 0, count: length)
                }
                #expect(LegacyLocalImportConsentModel().present(value) == nil)
            }
        }
    }

    @Test func replacementAndReopenDoNotReuseConfirmation() throws {
        let model = LegacyLocalImportConsentModel()
        let value = observation()
        let old = try #require(model.present(value))
        let new = try #require(model.present(value))
        #expect(!model.confirm(old, current: value))
        #expect(model.confirm(new, current: value))
        let reopened = LegacyLocalImportConsentModel()
        #expect(!reopened.confirm(new, current: value))
        #expect(reopened.state == .idle)
        model.invalidate()
        #expect(!model.confirm(new, current: value))
    }

    @Test func invalidPresentationRevokesPreviousProposal() throws {
        let model = LegacyLocalImportConsentModel()
        let value = observation()
        let old = try #require(model.present(value))
        var malformed = value
        malformed.backupDigest = Data()
        #expect(model.present(malformed) == nil)
        #expect(model.state == .invalidated)
        #expect(!model.confirm(old, current: value))
    }
}
