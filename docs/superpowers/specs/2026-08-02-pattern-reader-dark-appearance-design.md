# Pattern Reader Dark Appearance Design

**Date:** 2026-08-02

**Status:** Approved in conversation; awaiting written-spec review

## Goal

Keep pattern reading comfortable at night without redesigning KnitNote's existing light watercolor interface. The pattern reader alone follows the actual system appearance. In system Dark Mode, its chrome becomes dark and PDF/image content uses an automatic night presentation while each pattern can remember an explicit request to show its original colors.

## Scope

This change applies to the pattern reader on iPhone, iPad, and Mac.

- Retain the existing light watercolor appearance outside the pattern reader.
- Make the presented pattern reader independently follow the operating system's current Light or Dark Mode.
- In Dark Mode, apply a reversible night-rendering effect to PDF and image pattern content only.
- Add one compact reader-toolbar control for switching the current pattern between night presentation and original colors.
- Persist that choice per `StoredPattern`, shared by every project linked to the same library pattern.

The following are explicitly unchanged:

- Source PDF and image files.
- Page number, zoom, scroll position, page transitions, and saved viewport state.
- Highlight position, appearance, interaction, and persistence.
- Handwriting markup appearance, interaction, files, and persistence.
- Counter controls and page controls.
- Pattern-page thumbnail rendering and selection behavior.
- StoreKit, trial, purchase, Watch, backup file inclusion, and release metadata.
- Projects, pattern library, yarn library, settings, forms, sheets outside the reader, and the app's existing watercolor palette.

## User Experience

### Reader-only system appearance

KnitNote retains its approved light watercolor presentation outside the reader. The pattern-reader presentation obtains the actual operating-system appearance independently of the app shell's forced light preference. Its navigation chrome, toolbar, background, materials, text, and controls use dark styling only while the operating system is in Dark Mode.

Leaving the reader returns to the unchanged light watercolor app. This avoids expanding the feature into a full-app dark-theme redesign.

### Pattern reader

When the system appearance is Dark Mode:

- A pattern defaults to night presentation.
- The PDF or image content receives an on-screen night-rendering effect.
- A compact moon/sun toolbar button switches between night presentation and original colors.
- The selected option is remembered for that pattern.

When the system appearance is Light Mode:

- Pattern content always displays its original colors.
- The stored Dark Mode preference remains intact for the next time the system enters Dark Mode.
- The toolbar control communicates that it affects Dark Mode presentation rather than altering the source file.

The night effect is limited to the document presentation layer. Highlight, handwriting, page controls, counters, toolbar content, and selection affordances remain outside the filtered layer and retain their approved colors.

### Shared pattern identity

The preference belongs to `StoredPattern`, not `PatternProjectUsage`. If one library pattern is linked to several projects, every reader entry for that pattern uses the same original-color preference.

## Data Model

Add a Boolean preference to `StoredPattern` representing whether that pattern should retain original colors in system Dark Mode.

- Default: `false`, meaning automatic night presentation.
- Decode missing values as `false` so existing archives and backups remain compatible.
- Encode the value with the pattern metadata.
- Do not duplicate, rewrite, or generate alternative PDF/image files.
- Do not add the preference to per-project reading state.

This is a display/accessibility preference rather than paid content creation. Updating it must remain available regardless of trial or purchase state.

Because the current 1.3 branch already owns the unpublished archive-version increment, this additive defaulted field does not introduce another archive-version increment. Compatibility tests must prove that archives without the field still decode to automatic night presentation.

## Architecture

### Appearance policy

Introduce a small platform-independent policy that resolves whether night rendering is active from:

- the current system color scheme; and
- the pattern's stored original-color preference.

Night rendering is active only when the system is dark and the pattern does not prefer original colors. This policy is independently unit tested and keeps view code declarative.

### System appearance source

The reader must not use SwiftUI's inherited `colorScheme`, because the app shell intentionally prefers light appearance. Add a narrow platform adapter that reports the actual operating-system appearance and publishes changes while the reader is open:

- On iOS/iPadOS, resolve the connected window scene's screen trait collection and refresh on relevant trait/application lifecycle changes.
- On macOS, resolve the application's effective system appearance and refresh when appearance changes.
- Hide platform APIs behind an injectable reader-facing source so the policy and reader reactions remain deterministic in tests.

If the platform source cannot resolve a dark style, fall back to light/original presentation rather than guessing from time of day.

### Store mutation

Add a narrow store API that updates only the selected pattern's Dark Mode original-color preference and persists through the existing transactional archive path.

- Reject a missing pattern without modifying memory or disk.
- Do not route the mutation through paid-feature authorization.
- Publish a new data generation only after persistence succeeds.
- On persistence failure, leave the published pattern unchanged.

### Rendering boundary

Apply an immediate, non-destructive visual transformation to the PDF/image representable only. The transformation must not wrap the entire reader canvas because that would also alter highlights, markup, controls, and accessibility affordances.

The document-only effect is a live color inversion followed by a 180-degree hue rotation. This turns white paper dark and black chart marks light while approximately retaining color families. Apply the modifiers directly to `PDFReaderView` and `ImageReaderView`, before the separate highlight and handwriting layers are composed. Original colors remain one tap away for color-critical patterns. No rendered dark-page cache is created.

### Reader control

Add one toolbar button with localized labels, hints, and state:

- Night presentation active: offer "Show Original Colors".
- Original colors active in Dark Mode: offer "Use Night Appearance".
- Light Mode: communicate that the stored option applies when Dark Mode is active.

The control updates only after the store mutation succeeds. If persistence fails, keep the previous state and present the existing save-failure alert.

## Error Handling

- A missing pattern produces no visual-state mutation and uses the existing save-failure presentation.
- A failed archive write leaves the prior preference visible and persisted.
- An unavailable or unresolved system-appearance signal degrades to the reader's existing light/original presentation rather than blocking the reader.
- Changing appearance must not reload the document, reset the viewport, or create a new reader session.

## Localization and Accessibility

Add Traditional Chinese and English strings for the night/original-color toolbar action and accessibility hint.

- VoiceOver identifies the current presentation and the result of activating the control.
- The toolbar target retains the existing minimum interactive size.
- The control does not depend on color alone; moon/sun symbols and text labels convey state.
- Dynamic Type and existing compact toolbar layout remain supported.

## Verification

### Automated

- Appearance policy truth table for light/dark/unresolved and preference states.
- Platform appearance-source contracts and reader reaction to an appearance change without reconstruction.
- `StoredPattern` decoding without the new field defaults correctly.
- Archive round trip preserves each pattern's preference.
- Store update succeeds for the selected pattern and does not affect other patterns or usages.
- Missing-pattern and persistence-failure cases do not publish partial state.
- Source contracts verify that the light app shell remains unchanged, the reader uses an independent system-appearance source, and the visual effect is scoped to document content rather than the full reader canvas.
- Traditional Chinese and English localization keys are complete.
- Full Swift test suite passes.
- iOS Simulator and macOS builds pass.

### Physical acceptance

On iPhone and iPad:

1. Open a black-and-white PDF in Light Mode and confirm original colors.
2. Switch the system to Dark Mode and confirm the open reader chrome and document presentation update without reopening.
3. Zoom, scroll, turn pages, rotate, and background/foreground the app; confirm viewport and highlights remain stable.
4. Switch the pattern to original colors, leave and reopen it, and confirm the preference is remembered.
5. Open the same pattern through another linked project and confirm the same preference.
6. Open another pattern and confirm it still defaults to night presentation.
7. Verify handwriting and highlight colors remain unchanged.
8. Repeat with a colored pattern and confirm the original-color control is clear and responsive.

On Mac, verify automatic reader-only appearance changes, toolbar accessibility, PDF/image night rendering, saved preference, and unaffected zoom/scroll behavior. Confirm that leaving the reader returns to the unchanged light watercolor app.

## Non-Goals

- Manual app-wide Light/Dark/System theme selector.
- Full-app Dark Mode or an adaptive redesign of watercolor screens.
- Brightness slider, color-temperature slider, or scheduled night mode.
- Modifying or exporting a transformed PDF/image.
- Dark-rendered page cache or duplicate document storage.
- Automatic analysis of whether a pattern is monochrome or colored.
