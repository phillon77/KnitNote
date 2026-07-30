# KnitNote Pricing Release Guard Design

Date: 2026-07-31  
Status: Approved direction, awaiting written-spec review

## Problem

KnitNote changed from a paid-download model to:

- free App download;
- seven-day local full-feature trial;
- one non-consumable Lifetime Unlock;
- no subscription.

Removing an App from sale changes availability but does not clear its current
App price or future App price schedule. When KnitNote was made available again,
the retained paid-download price and future paid-price change became public
again. The repository also retained historical pricing documents whose old App
download prices could be mistaken for the current commercial configuration.

The release process must treat these as separate state:

1. App binary and entitlement behavior;
2. App download price;
3. App price schedule;
4. App availability;
5. Lifetime Unlock product, price, and availability;
6. public storefront propagation.

No single green build or App Store Connect status proves all six.

## Current Commercial Contract

The only valid KnitNote commercial contract is:

| Item | Required value |
| --- | --- |
| App download | Free in all 175 storefronts |
| Future App price changes | None |
| Trial | Seven days, stored locally |
| Lifetime Unlock product ID | `com.phillon.KnitNote.lifetimeUnlock` |
| Lifetime Unlock type | Non-consumable |
| Lifetime Unlock United States price | US$4.99 |
| Lifetime Unlock Taiwan price | NT$150 |
| Subscription | None |
| Existing verified permanent entitlement | Must remain permanent |

Historical paid-download prices belong only in a clearly marked history
section and must never appear as executable instructions.

## Considered Approaches

### A. Documentation only

Update the pricing document and add a manual checklist.

This is low effort, but it still allows a release to proceed while the document
and App Store Connect disagree.

### B. Canonical configuration, offline guard, live storefront check

Add one machine-readable commercial configuration, make all human
documentation point to it, add an offline validation command to the existing
release audit, and add an explicit live storefront verification command.

This catches stale repository instructions automatically, requires no App Store
Connect credentials, and verifies the public App download price. App Store
Connect-only facts and StoreKit purchase-sheet prices remain manual evidence
gates.

This is the selected approach.

### C. Full App Store Connect API enforcement

Query App price schedules, availability, and In-App Purchase metadata directly
with App Store Connect API credentials.

This provides the strongest automation but adds private-key handling, issuer
and key configuration, network failure handling, and credential rotation. It
is deferred until the credential-management boundary is explicitly approved.

## Components

### 1. Canonical commercial configuration

Add `AppStore/CommercialConfiguration.json` as the machine-readable source of
truth. It records:

- Apple ID and bundle ID;
- free App download requirement;
- 175-storefront requirement;
- empty future App price schedule requirement;
- seven-day trial;
- Lifetime Unlock product ID and non-consumable type;
- expected United States and Taiwan Lifetime Unlock prices;
- no-subscription requirement.

`AppStore/KnitNotePricing.md` becomes the human-readable explanation of this
current contract. The old 1.0 paid-download values move to a historical appendix
with an explicit non-executable warning.

### 2. Commercial release checklist

Add `AppStore/Verification/CommercialReleaseChecklist.md`. Each release or
re-listing must record:

- immutable Git SHA, version, build, archive identity, and selected App Store
  Connect builds;
- App price detail showing zero in the United States and Taiwan and all 175
  storefronts;
- confirmation that the App price schedule contains no future entries;
- App availability for all intended storefronts;
- Lifetime Unlock approval, type, product ID, and United States/Taiwan prices;
- public Taiwan and United States storefront prices after propagation;
- fresh-download trial, purchase, restore, relaunch, iOS, and macOS acceptance;
- advertising hold until every gate passes.

Unchecked fields are failures, not informational reminders.

### 3. Offline commercial configuration guard

Add `AppStore/Verification/commercial_release_check.py`.

Offline validation checks:

- the canonical JSON schema and exact required values;
- the current pricing document points to the canonical JSON;
- executable release documentation does not describe KnitNote as a paid
  download or schedule a future App price;
- the product ID matches the source contract;
- the commercial checklist contains every required release gate.

`AppStore/Verification/release_audit.sh --static-only` invokes this offline
check so stale commercial instructions block the normal release audit.

### 4. Live public storefront guard

The same command supports a live mode that queries Apple's public lookup
endpoint for Taiwan and the United States and requires:

- Apple ID `6793023054`;
- bundle ID `com.phillon.KnitNote`;
- App download price `0`;
- the expected storefront currency;
- the public result to identify In-App Purchases.

Live mode reports public propagation only. It must not claim that Lifetime
Unlock pricing, restore behavior, or App Store Connect schedules are correct.
Those remain separate checklist gates.

### 5. Test suite

Add focused Python tests before implementation. Tests cover:

- the approved configuration passes;
- a paid App download value fails;
- a future App price entry fails;
- a wrong Lifetime Unlock product ID or price fails;
- missing checklist gates fail;
- Taiwan or United States public paid-download responses fail;
- zero-price public responses pass;
- malformed, missing, empty, or mismatched lookup responses fail closed;
- network failure produces a clear non-zero result and never reports success.

The tests use local fixtures and dependency injection; they never depend on the
live network.

## Release Flow

The mandatory order is:

1. Freeze and identify the exact candidate SHA, version, build, and archives.
2. Run the complete local release audit, including the offline commercial
   guard.
3. Verify Lifetime Unlock and the candidate in App Store Connect.
4. While the App is unavailable, verify the App download price is zero in all
   175 storefronts and delete every future App price change.
5. Re-enable App availability.
6. Run the live public storefront guard until Taiwan and the United States are
   free.
7. Install the public build and complete trial, purchase, restore, relaunch,
   iOS, and macOS acceptance.
8. Start advertising only after the checklist contains evidence for every gate.

Availability must never be enabled before steps 1 through 4 are complete.

## Error Handling

- Missing or malformed configuration fails closed.
- Missing live network access fails without changing any external state.
- A public price mismatch reports which storefront and observed value failed.
- A stale or incomplete checklist fails the offline release audit.
- App Store Connect writes remain manual and require explicit authorization.
- The guard performs no App Store Connect, pricing, availability, advertising,
  Git push, or release mutation.

## Success Criteria

The design is complete when:

- only one current commercial configuration exists;
- historical paid-download data cannot be mistaken for current instructions;
- the normal release audit rejects a wrong App price model or incomplete gate
  structure;
- a standalone live command verifies free public downloads in Taiwan and the
  United States;
- the checklist prevents availability or advertising before all independent
  commercial gates have evidence;
- all focused tests, the static release audit, and the complete existing test
  suite pass.
