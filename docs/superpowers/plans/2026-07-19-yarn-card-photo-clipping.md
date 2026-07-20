# Yarn Card Photo Clipping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep every yarn photo inside a square card image frame on iPhone and iPad.

**Architecture:** Constrain `YarnPhotoView` at its use site in `YarnCard`, because the same photo view is also used by the detail and editor screens. Apply the square aspect ratio to the outer image container and clip its contents before applying the existing rounded shape.

**Tech Stack:** SwiftUI, Swift Testing, Xcode iOS Simulator

## Global Constraints

- Keep yarn photos centered and proportionally filled without stretching.
- Keep the current 16-point continuous rounded corners.
- Do not change saved yarn data or photo files.
- Preserve the existing adaptive iPhone and iPad grid.

---

### Task 1: Constrain yarn card photos

**Files:**
- Modify: `Tests/KnitNoteCoreTests/YarnViewContractTests.swift`
- Modify: `KnitNote/Yarn/YarnCard.swift`

**Interfaces:**
- Consumes: `YarnPhotoView(url:)` and the existing adaptive `LazyVGrid` card width.
- Produces: A square, clipped `YarnCard` photo region.

- [ ] **Step 1: Write the failing source contract test**

Add these assertions to `yarnCardsKeepFullNamesAndPrioritizeBallsThenGrams`:

```swift
#expect(card.contains(".aspectRatio(1, contentMode: .fit)"))
#expect(card.contains(".clipped()"))
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter YarnViewContractTests/yarnCardsKeepFullNamesAndPrioritizeBallsThenGrams
```

Expected: FAIL because `YarnCard.swift` does not contain the square outer aspect ratio and explicit clipping contract.

- [ ] **Step 3: Implement the minimal SwiftUI constraint**

Replace the current `YarnPhotoView` modifier chain with:

```swift
YarnPhotoView(url: photoURL)
    .frame(maxWidth: .infinity)
    .aspectRatio(1, contentMode: .fit)
    .clipped()
    .clipShape(.rect(cornerRadius: 16, style: .continuous))
```

- [ ] **Step 4: Run focused and full verification**

Run:

```bash
swift test --filter YarnViewContractTests/yarnCardsKeepFullNamesAndPrioritizeBallsThenGrams
swift test --disable-sandbox
git diff --check
```

Expected: focused test PASS, all tests PASS, and no whitespace errors.

- [ ] **Step 5: Build and visually verify**

Build and run `KnitNote` in iPhone and iPad simulators. Confirm portrait photos stay inside a square frame, adjacent cards do not overlap, and metadata remains below the photo.
