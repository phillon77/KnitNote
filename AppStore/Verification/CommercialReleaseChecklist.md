# KnitNote Commercial Release Checklist

此文件是每次 release 或 re-listing 的強制證據模板。未勾選或沒有日期、
操作者與候選版本證據的項目一律視為失敗。

## Reusable template

### Candidate identity

- [ ] Candidate SHA:
- [ ] Version and build:
- [ ] iOS archive identity:
- [ ] macOS archive identity:
- [ ] App Store Connect selected builds:

### App price and availability

- [ ] App download price is 0 in all 175 storefronts.
- [ ] United States App price is US$0.00.
- [ ] Taiwan App price is NT$0.
- [ ] No future App price changes are scheduled.
- [ ] Availability matches the intended 175 storefronts.

### Lifetime Unlock

- [ ] Product ID is `com.phillon.KnitNote.lifetimeUnlock`.
- [ ] Type is non-consumable and status is approved.
- [ ] Lifetime Unlock price is US$4.99 in the United States.
- [ ] Lifetime Unlock price is NT$150 in Taiwan.

### Public and device acceptance

- [ ] Taiwan public storefront shows free App download and App內購買.
- [ ] United States public storefront shows Free and In-App Purchases.
- [ ] A fresh public install shows the seven-day trial.
- [ ] Purchase sheet shows the expected local Lifetime Unlock price.
- [ ] Lifetime Unlock survives relaunch.
- [ ] Restore purchase succeeds without a second charge.
- [ ] iOS acceptance passed on the exact public candidate.
- [ ] macOS acceptance passed on the exact public candidate.

### Advertising gate

- [ ] advertising remains blocked until every item above has dated evidence.

## Incident record — 2026-07-31

This record captures the pricing incident and recovery. It is not a completed
release checklist for a future candidate.

### Verified App Store Connect and public state

- [x] 2026-07-31: App download price was US$0.00 in the United States,
  NT$0 in Taiwan, and zero across all 175 storefronts.
- [x] 2026-07-31: No future App price changes remained after the obsolete
  2026-08-23 paid-App adjustment was deleted.
- [x] 2026-07-31: Lifetime Unlock product ID
  `com.phillon.KnitNote.lifetimeUnlock` was approved and non-consumable.
- [x] 2026-07-31: Lifetime Unlock price remained US$4.99 in the United States
  and NT$150 in Taiwan.
- [x] 2026-07-31: Taiwan public storefront showed
  `免費 · App內購買`.
- [x] 2026-07-31: United States public storefront showed
  `Free · In-App Purchases`.

### Earlier TestFlight evidence, not public-build acceptance

- [x] 2026-07-29: iOS TestFlight showed the expected Lifetime Unlock purchase
  sheet and completed a test transaction without a real charge.
- [x] 2026-07-29: The TestFlight entitlement survived app relaunch.
- [ ] Fresh public iOS install, seven-day trial, purchase, relaunch, and
  restore purchase acceptance for the exact public candidate.
- [ ] Fresh public macOS install, seven-day trial, purchase or restore,
  relaunch, and persistence acceptance for the exact public candidate.

### Advertising status

- [ ] advertising remains blocked until the two public-candidate acceptance
  rows above contain dated device, OS, version, and build evidence.
