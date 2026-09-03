# Task 1 — CKRecord codec report

## Implementation

- Added `KnitNote/CloudSync/CloudRecordCodec.swift` to the iOS/macOS `KnitNote` target only. It imports CloudKit at the concrete transport boundary; no CloudKit import or target membership was added to `Sources/KnitNoteCore` or the Watch target.
- `CloudRecordCodec` maps every `SyncEntityKind` raw value to its own CKRecord type, and uses a deterministic, privacy-safe record name of `kind-lowercase-uuid`.
- Encodes versioned field maps, deletion cascade, atomic domain, attachment metadata, and mutation stamps as sorted-key JSON `Data`; relationships use explicit parallel role/kind/UUID fields. No `CKAsset` is created or required.
- The non-asset wire representation is measured as canonical JSON and rejected above 256 KB. Decode ignores unknown fields, rejects malformed identity/relationship metadata and fractional schema values, and routes the reconstructed record through `SyncRecordValidator` so schema/domain validation remains fail-closed.

## Files

- `KnitNote/CloudSync/CloudRecordCodec.swift`
- `Tests/KnitNoteAppTests/CloudRecordCodecTests.swift`
- `KnitNote.xcodeproj/project.pbxproj`

## TDD evidence

1. RED: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests/CloudRecordCodecTests` failed with `Cannot find 'CloudRecordCodec' in scope` and `Cannot find 'CloudRecordCodecError' in scope` before production code existed. The sandbox first blocked DerivedData; rerunning with approved access exposed the expected missing-code failure.
2. RED regression: after adding the fractional-schema test, `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests/CloudRecordCodecTests CODE_SIGNING_ALLOWED=NO` failed only `rejectsFractionalSchemaMetadataInsteadOfTruncatingIt`.
3. GREEN: the same focused command passed `CloudRecordCodecTests` (seven tests) after `requiredInt` rejects non-integral metadata. The unmodified command reaches Xcode signing and fails because this environment cannot replace the existing DerivedData app signature; `CODE_SIGNING_ALLOWED=NO` was required solely for local test execution.

## Validation commands/results

- `git diff --check` — pass.
- `plutil -lint KnitNote.xcodeproj/project.pbxproj` — `OK`.
- `swift test --scratch-path /tmp/KnitNotePlan2Task1 -q` — completed 2,044 tests in 155 suites but failed with one pre-existing/unrelated issue: `PatternShareInboxEnqueuerTests.cancellationDuringCandidateCopyPublishesNothingAndCleansEveryArtifact` timed out waiting for a file-copy event. Output also reports missing temporary release archive artifacts and existing compiler warnings. This task does not touch the share enqueuer, release audit, or Core package sources.

## Self-review

- Schema completeness: `SyncEntityKind.allCases` is compared with the complete explicit current type set, including `watchCommandProof`; a future case changes the test result.
- Payload size: limit applies to the encoded non-asset `WirePayload`, including JSON-encoded attachment metadata and relationship fields; the 256 KB scalar boundary test is rejected after its wire expansion.
- Relationships: role, target kind, and UUID are represented explicitly, cardinalities and legal roles are still checked by `SyncRecordValidator`, and array order round-trips unchanged.
- Validation and privacy: record names contain only kind and UUID; decoded records must match that identity and pass the existing validator. Unknown optional fields are ignored. No user text enters record names.

## Concern

Focused codec tests pass, but the required full `swift test` suite has the unrelated single failure noted above; this task is therefore handed off as `DONE_WITH_CONCERNS`.
