# Compact Counter Controls Design

**Date:** 2026-08-10
**Target:** KnitNote 1.5.0 (Build 9)

## Problem

The counter manager currently shows localized action titles beside minus and plus icons. On iPhone, translations such as Traditional Chinese “減少計數器” and “增加計數器” have unequal visual width and crowd the reset action.

## Approved design

- Replace the visible decrement title with `−1`.
- Replace the visible increment title with `+1`.
- Replace the reset title with `0` while keeping the `arrow.counterclockwise` symbol visible.
- Give all three value controls equal sizing so none appears more important.
- Preserve a minimum 44-point interactive height.
- Keep the existing localized full action names as VoiceOver accessibility labels.

The compact symbols are deliberately language-neutral. No String Catalog entries are removed because the full localized labels remain required for accessibility.

## Behavior and data boundaries

- `−1` continues to clamp at zero and remains disabled at zero.
- `+1` continues to stop at the maximum integer value.
- `↶ 0` continues to require its existing confirmation dialog.
- Reminder behavior, counter persistence, project data, Watch synchronization, and user-created content are unchanged.

## Verification

- Add a source contract proving the visible labels are `−1`, `+1`, and `↶ 0`.
- Prove all three buttons retain the existing localized accessibility labels.
- Prove all three compact controls retain at least a 44-point target and equal sizing.
- Run focused counter-view and localization contracts, then iOS and macOS builds.
- Repeat the iPhone counter-manager physical check before continuing reminder acceptance.
