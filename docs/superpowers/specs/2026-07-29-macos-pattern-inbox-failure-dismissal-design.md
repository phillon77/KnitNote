# macOS Pattern Inbox Failure Dismissal Design

## Problem

KnitNote 1.2.1 Build 4 can encounter a general pattern-inbox read failure at launch. In this failure mode, `PatternInboxFailure.itemID` is `nil`, so the alert shows Retry but cannot show Discard. The alert binding also ignores dismissal, leaving the user trapped in a retry-only loop and unable to enter the app.

The fix must preserve all existing project data and pending shared files. It must not change StoreKit behavior or silently discard an inbox item.

## User Experience

- A failure tied to a specific inbox item continues to offer Retry and Discard.
- A general inbox read failure offers Retry and Later.
- Choosing Later closes the alert without deleting or modifying any inbox file.
- When the app next becomes active, the existing foreground processing path scans the inbox again.

## Design

`PatternInboxProcessor` will expose `dismissFailure()`. The method only sets the published failure state to `nil`.

`RootView` will use the failure type to choose its secondary action:

- `itemID != nil`: show the existing destructive Discard action.
- `itemID == nil`: show a non-destructive, cancel-role Later action that calls `dismissFailure()`.

The alert binding remains driven by processor state. No storage service, archive format, entitlement logic, or inbox recovery algorithm changes.

## Error Handling and Data Safety

Retry continues to re-run the inbox processor.

Discard remains available only when the driver identifies the exact failed item. General failures can never delete an unknown item.

Later clears only transient presentation state. The pending inbox and project archive remain untouched, and foreground activation retains the existing retry opportunity.

## Testing

Add focused contract coverage proving:

1. The processor exposes a non-destructive failure-dismissal action.
2. The general-failure branch in `RootView` presents a localized Later action and invokes dismissal.
3. The item-specific branch retains the existing Discard action.
4. Traditional Chinese and English include the Later localization.

Run the focused inbox tests, the full Swift test suite, macOS Release build verification, and finally reinstall and launch the TestFlight candidate on macOS. Physical acceptance requires:

- the general failure alert can be dismissed;
- existing projects remain present;
- no trial prompt appears for the previously verified lifetime entitlement;
- a project can be created;
- quitting and reopening preserves entitlement and data.

## Out of Scope

- Deleting or repairing the currently pending shared file.
- Changing the pattern-inbox storage or recovery format.
- Changing StoreKit, trial, or lifetime entitlement rules.
- Publishing the existing macOS 1.2.0 version.
