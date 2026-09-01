# Task 8 Report — Apple Watch Reminder Queue UI

## Scope

Replaced the temporary Watch counter reminder card with the schema-4 project reminder queue. The Watch renders one occurrence at a time and sends only schema-3 durable complete, remind-next-row, or skip payloads.

## RED / GREEN

- The new source-contract tests initially failed because the queue view, phase controls, schema-3 payload wiring, and bridge removal did not exist.
- The final Watch UI, connectivity, phone/watch queue, and packaging run passed 42 tests.

## Changes

- Added `KnittingReminderQueueView`, showing semantic kind, verbatim custom text, original target, phase, and queue position.
- Initial occurrences expose Complete and Remind Next Row; deferred occurrences expose Complete and Skip This Time. Controls disable while a counter command is pending and retain 44-point minimum heights.
- `WatchSyncCoordinator` now builds `WatchReminderActionPayload` from exact project, counter, reminder, occurrence, and revision identifiers.
- Removed the legacy card from the Watch UI and snapshot builder. Schema-2 decoding remains available only for recovery fixtures; production UI does not construct schema-2 commands.
- Optimistic-increment haptic detection now uses visible occurrence identifiers rather than reminder identifiers.

## Verification

- `swift test --disable-sandbox --filter 'WatchCounterViewContractTests|WatchConnectivityAdapterSourceContractTests|PhoneWatchSyncSourceContractTests|WatchPackagingContractTests'` — 42 passed.
- `xcodegen generate` — passed.
- `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build` — passed.
- `git diff --check` — passed.

## Follow-on work

Task 9 owns the full 13-language catalog. This Task 8 view has English fallback copy so raw identifiers are never displayed. Persistent cross-snapshot haptic-ledger coverage and separate initial/deferred screenshot fixture variants remain follow-on acceptance work.
