# KnitNote Watch Counter Sync Design

Date: 2026-07-21
Status: Approved for specification review

## Objective

Replace the current sample-only Watch counter with a production companion for KnitNote 1.0. The Watch app shows projects and all six named counters from the iPhone app, accepts counter changes while reachable or offline, and converges on the authoritative iPhone state without duplicate mutations.

The Watch companion does not display patterns, notes, photos, yarn inventory, journals, calculators, backup controls, project editing, or counter-name editing in version 1.0.

## Product Behavior

The Watch app presents two levels:

1. a compact list of projects ordered by most recently updated;
2. the selected project's six counters in a vertically scrollable list.

Active projects appear before completed projects. Completed projects remain visible for context but are read-only. Each counter row shows the complete user-defined name and current value. Tapping a counter increments it by one. A long press opens a small action sheet containing decrement by one and reset to zero. Counter renaming remains an iPhone, iPad, or Mac action.

The Watch shows a subtle status when changes are waiting for the iPhone. It does not block normal counting merely because the iPhone is temporarily unreachable. After reconnecting, pending operations synchronize automatically and the screen refreshes to the iPhone-confirmed state.

## Authority and Data Boundary

`JSONProjectStore` on the paired iPhone is the only authoritative project store. The Watch keeps a compact local cache and a durable queue of counter commands. It never writes directly to the iPhone project archive and does not copy photos, patterns, notes, journal images, yarn data, or backups.

Communication uses Apple's `WatchConnectivity` framework. No developer server, third-party service, account, analytics SDK, or internet connection is introduced.

The iPhone publishes a compact snapshot containing:

- snapshot schema version;
- snapshot generation date;
- project identifier, name, completion state, and update date;
- exactly six counter identifiers, complete display names, and values;
- the selected counter identifier for each project.

The Watch stores only this snapshot plus its pending command queue and presentation selection.

## Command Model

Every Watch mutation is a command with:

- a unique command identifier;
- project identifier;
- counter identifier;
- operation: increment, decrement, or reset;
- creation date;
- command schema version.

The Watch appends the command to its durable queue before changing the displayed optimistic value. Commands retain their original order. A reachable iPhone receives commands immediately; unreachable commands remain queued and are transferred when connectivity resumes.

The iPhone maintains a bounded durable set of processed command identifiers. It ignores an already-processed identifier and returns the current authoritative snapshot, which makes retries safe. New commands are applied to the iPhone's current counter state in queue order:

- increment adds one;
- decrement subtracts one without going below zero;
- reset sets the value to zero.

The iPhone rejects a command when the project is completed, the project no longer exists, the counter no longer exists, or the schema version is unsupported. Rejection is not retried indefinitely. The Watch removes the rejected command after acknowledgement, replaces optimistic values with the returned snapshot, and displays a localized concise explanation.

## Transport Strategy

The connectivity layer uses three complementary WatchConnectivity paths:

- `updateApplicationContext` carries the newest complete project snapshot; newer snapshots replace older unsent snapshots.
- `sendMessage` carries a command when the counterpart is reachable and returns a prompt acknowledgement and snapshot.
- background transfer carries durable queued commands when immediate messaging is unavailable.

Transport delivery is treated as at-least-once. Command identifiers and iPhone-side deduplication provide exactly-once mutation effects from the user's perspective.

After launch, activation, reconnection, an accepted command, a rejected command, a project edit, project completion or resumption, counter rename, or counter mutation on the iPhone, the iPhone schedules a fresh application-context snapshot.

## Persistence

The Watch persists its latest valid snapshot and pending commands as versioned JSON in Application Support using atomic replacement. The selected project and counter identifiers are stored with the cache and restored only when they still exist in the latest snapshot.

The iPhone persists processed command identifiers alongside project data in a focused synchronization file. The set is pruned by both age and count only after commands have been acknowledged; it retains at least the most recent 1,000 identifiers and at least 90 days of history so normal delayed transfers remain deduplicated.

Malformed cache or command files are quarantined and replaced with a clean empty state. This recovery must not modify iPhone project data.

## Concurrency and Conflict Rules

All connectivity callbacks cross into a single serialized synchronization coordinator before reading or mutating state. UI publication occurs on the main actor.

The iPhone applies a valid queued operation to whatever authoritative value exists when it receives the operation. This preserves the user's intent when both devices have counted while disconnected. Reset is deliberately authoritative at its ordered position in the queue.

The iPhone snapshot always wins over optimistic Watch presentation after acknowledgement. If the project is completed before queued operations arrive, those operations are rejected and the completed snapshot replaces the Watch values.

## Localization and Accessibility

All Watch labels, pending-state messages, errors, counter actions, and empty states are localized in Traditional Chinese and English. User-defined project and counter names are never abbreviated in stored data; the UI may wrap or scroll them when space is constrained.

Counter rows expose project name, counter name, value, and action hints to VoiceOver. Increment, decrement, and reset have distinct accessible actions. Color is not the only indication of pending, completed, selected, or error state. Tap targets follow watchOS accessibility guidance.

## Packaging

The Watch product is packaged as the Apple-supported companion of the KnitNote iOS app and associated with the App Store record whose Apple ID is `6793023054`. The main app retains `com.phillon.KnitNote`; the Watch app retains `com.phillon.KnitNote.watch` unless Xcode requires an additional extension identifier derived from it.

The iOS Release archive must contain or validly associate the Watch product, its localized resources, icon catalog, privacy manifest when applicable, and version/build metadata. App Store upload validation must recognize the Watch screenshots slot for the KnitNote record.

## Failure Handling

- No paired or installed Watch: the iPhone continues normally without alerts.
- Connectivity unavailable: commands stay queued and the Watch shows a pending status.
- Activation failure: cached data remains usable and retry occurs on the next lifecycle opportunity.
- Unsupported schema: mutation is rejected without changing project data and both apps request an updated compatible snapshot.
- Corrupt Watch cache: quarantine it, start empty, and request a snapshot.
- Corrupt deduplication file: do not apply unverified queued commands automatically; rebuild the file and require a fresh synchronization handshake.
- Storage failure: keep the last durable state, show a localized error, and do not falsely mark a command as acknowledged.

## Verification

Automated tests cover:

- snapshot encoding, decoding, version rejection, and six-counter invariants;
- command encoding and ordered application;
- increment, floor-at-zero decrement, and reset;
- durable queue recovery after process restart;
- duplicate delivery producing one mutation;
- offline commands replayed after reconnection;
- commands and iPhone-side mutations interleaved deterministically;
- completed, deleted, or changed projects rejecting stale commands;
- corrupted cache and deduplication recovery;
- Traditional Chinese and English localization completeness;
- source contracts for WatchConnectivity delegates and Watch target packaging.

Manual verification covers:

1. initial pairing and first snapshot;
2. immediate Watch-to-iPhone counting;
3. iPhone-to-Watch counter and name changes;
4. Airplane Mode counting followed by reconnection;
5. repeated delivery without duplicate increments;
6. Watch and iPhone process termination with pending work;
7. project completion and resumption;
8. all six counters with long names and VoiceOver;
9. signed Release archive and App Store upload validation.

## Out of Scope

- iCloud or server synchronization;
- pattern/PDF viewing on Watch;
- row notes, page notes, or handwriting on Watch;
- photos, journal, yarn inventory, calculators, or backups on Watch;
- project creation, deletion, completion, or editing on Watch;
- counter renaming on Watch;
- complications, widgets, Smart Stack controls, or Live Activities;
- multiple iPhone authority resolution.
