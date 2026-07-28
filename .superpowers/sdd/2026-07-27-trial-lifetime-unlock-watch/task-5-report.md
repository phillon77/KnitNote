# Task 5 Report — Trial Pill, Unlock Sheet, Restore, and Redeem

## Scope

- Base: `9b59695`
- Added the projects-home trial pill and one centrally presented unlock sheet.
- Added coordinator façade methods for localized lifetime price, purchase,
  restore, forced refresh, and sheet dismissal without exposing
  `PurchaseService` to SwiftUI.
- Added English and Traditional Chinese copy, VoiceOver labels, purchase
  pending/cancellation/retry handling, restore, and offer-code redemption.
- Added no Watch entitlement payload, Share Extension entitlement projection,
  or yarn-label feature.

## TDD evidence

### Presentation and contracts

The first focused RED run failed because `UnlockPresentation` did not exist.
The implementation added calendar-safe rounded-up trial days, the retained-data
copy key, a projects-only pill, and one `RootView` unlock sheet used by both the
pill and blocked mutations.

The expiry regression test then failed because the pill checked entitlement
state outside its timeline. The state check moved inside `TimelineView`, and a
boundary test now verifies that the trial remains active immediately before
expiry and ends exactly at expiry.

### Purchase façade

Coordinator tests were written before the façade and failed to compile because
`refreshEntitlement`, `localizedLifetimePrice`, `purchaseLifetime`,
`restorePurchases`, and `dismissUnlock` were missing. The GREEN implementation
keeps `PurchaseService` private while exposing only the operations the sheet
needs. Busy state disables duplicate purchase, restore, redeem, and dismissal
actions.

### Review-fix RED

Independent review found four Important gaps and two Minor copy/presentation
issues:

1. verified `Transaction.updates` were finished but not published to the
   coordinator;
2. an authoritative refresh could join a stale startup flight without opening
   a newer StoreKit qualification flight;
3. offer-code redemption existed only on iOS even though macOS 15 supports it;
4. an hourly timeline could leave an expired pill visible too long;
5. active trials displayed read-only copy;
6. English displayed “1 days”.

New tests cover startup/refresh overlap, pending purchase followed by a
verified transaction update, StoreKit update publication and listener
lifecycle, expiry boundary behavior, minute-level timeline refresh, macOS
redemption, and singular/plural English and Traditional Chinese keys.

The pending-update test initially asserted after
`currentQualification()` returned but before the coordinator published the
flight result. Instrumented phase output proved every awaited service step
completed and the failure was test ordering, not a production deadlock. The
test now waits for the coordinator's published `.permanentlyUnlocked`
snapshot before asserting.

## Implementation

- `TrialStatusPill` renders only for active trials on the projects home,
  refreshes every minute, rounds partial days up, uses correct singular/plural
  copy, and opens the central unlock sheet.
- `UnlockSheet` uses `Product.displayPrice` through the coordinator façade,
  shows neutral pending/cancelled states, restores purchases, retains the
  user's data after expiry, and keeps read-only copy restricted to expired
  trials.
- Offer-code redemption uses
  `AppStore.presentOfferCodeRedeemSheet(in:)` with a foreground
  `UIWindowScene` on iOS and
  `AppStore.presentOfferCodeRedeemSheet(from:)` with a visible
  `NSViewController` on macOS.
- `StoreKitPurchaseService` publishes each verified transaction update through
  an `AsyncStream` after finishing it. Service teardown cancels the listener
  task and finishes the stream.
- `EntitlementCoordinator` listens to the stream with a weak-self task,
  cancels it on teardown, and performs an authoritative forced refresh. If a
  startup flight is running, refresh waits for it and then starts a distinct
  new qualification flight before publishing the final state.
- `RootView` observes verified snapshot publication so a pending purchase or
  redeemed code that qualifies later also dismisses an already-open sheet.
- Successful purchase, restore, redemption, and deferred transaction
  qualification dismiss the unlock request. Pending and cancelled purchase
  outcomes leave the sheet available.

## Localization and accessibility

- English and Traditional Chinese cover title, trial state, expiry/data
  retention, lifetime purchase, pending, cancellation, restore, redemption,
  retry, read-only state, Watch guidance, and all action labels.
- One-day copy is grammatically singular in both visible and VoiceOver text.
- Purchase, restore, redeem, and dismiss actions have explicit VoiceOver
  labels.
- Dynamic formatted copy receives SwiftUI's environment locale, so KnitNote's
  in-app English/Traditional Chinese selection is respected even when it
  differs from the system language.
- When StoreKit has loaded a price, the purchase button's VoiceOver label
  includes that localized price instead of replacing it with a generic label.

## Final accessibility review fix

The latest independent review found two Important accessibility/localization
gaps and no Critical issues. RED contract tests reported six issues because
the views had no environment locale, dynamic lookups omitted `locale:`, and
the priced VoiceOver key/label did not exist. The GREEN implementation injects
`@Environment(\.locale)` in both views, passes it to every dynamic lookup, and
adds localized priced purchase labels in English and Traditional Chinese.

## Verification

| Command | Result |
| --- | --- |
| `swift test --filter Unlock` | 10 tests in 2 suites passed |
| `swift test` | 898 tests in 75 suites passed |
| forced-refresh exact app test | 1 test passed |
| pending transaction-update exact app test | 1 test passed |
| StoreKit update/lifecycle exact app tests | 2 tests passed |
| Full `KnitNoteAppTests` | 23 tests / 25 executions passed |
| unsigned generic iOS Simulator build | passed |
| unsigned generic macOS build | passed |
| `jq empty Localizable.xcstrings` | passed |

The full Swift suite emitted the pre-existing CoreGraphics PDF diagnostic but
had no failures.

## Limitations

- Deterministic seams cover StoreKit outcomes and transaction-update delivery;
  no sandbox purchase, restore, or offer-code redemption was completed on a
  physical device in this task.
- Apple Watch entitlement synchronization and offline read-only behavior belong
  to the following plan task.
