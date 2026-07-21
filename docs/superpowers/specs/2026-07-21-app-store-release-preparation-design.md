# KnitNote App Store Release Preparation Design

Date: 2026-07-21
Status: Approved for specification review

## Objective

Prepare KnitNote 1.0 for a simultaneous App Store release on iPhone, iPad, Apple Watch, and macOS. The release package must be bilingual in Traditional Chinese and English, accurately describe only implemented functionality, preserve the app's watercolor family identity, and remain reusable for later App Store updates.

The work ends immediately before the irreversible App Store Connect action that submits the versions for App Review. The account holder reviews the completed listing and explicitly authorizes submission in a separate step.

The release depends on the approved companion specification `docs/superpowers/specs/2026-07-21-watch-counter-sync-design.md`. Store copy and Watch screenshots may describe synchronized project counters only after that specification is implemented and verified.

## Confirmed Commercial Configuration

- App Store name: KnitNote
- Apple ID: `6793023054`
- Main bundle identifier: `com.phillon.KnitNote`
- Watch bundle identifier: `com.phillon.KnitNote.watch`
- Release version: 1.0
- Platforms: iPhone, iPad, Apple Watch, and macOS
- Business model: paid download, one-time purchase
- Introductory United States price: US$2.99
- Current Taiwan equivalent: NT$90
- Availability: all 175 App Store countries or regions
- Standard United States price: US$4.99 beginning on the thirty-first day after public release
- Release control: manual release after App Review approval
- Public support email: `lzz.1999@icloud.com`

The price change cannot be scheduled until the actual public release date is known. The release record must capture that date, calculate the thirtieth full promotional day, and schedule US$4.99 for the following day.

## Release Artifact Structure

All reusable submission sources live under `AppStore/`:

- `AppStore/AppStoreSubmission.md` records every App Store Connect field, its approved value, completion state, and final submission checklist.
- `AppStore/Metadata/zh-Hant.md` contains the Traditional Chinese product-page copy.
- `AppStore/Metadata/en-US.md` contains the United States English product-page copy.
- `AppStore/PrivacyPolicy.md` is the bilingual source of truth for the public privacy policy.
- `AppStore/SupportSite/` contains a static bilingual GitHub Pages site.
- `AppStore/Screenshots/` contains screenshot specifications, capture instructions, compositing tooling, and generated deliverables.
- `AppStore/KnitNotePricing.md` remains the source of truth for pricing, agreement status, and the post-launch adjustment.

App Store Connect remains the publishing system of record. Repository files are the reviewable and repeatable source material used to populate it.

## Store Metadata

Traditional Chinese is the primary App Store language. English (United States) is the second localization. Each localization includes:

- app name and subtitle;
- promotional text;
- full description;
- keyword list;
- support URL;
- marketing URL when the support site provides a suitable landing section;
- version 1.0 release notes.

Copy emphasizes the implemented daily workflow: project management, six named counters, per-row notes, PDF and image patterns, page-specific notes, horizontal and combined highlighting, handwritten pattern markup, pattern-linked counters, knitting journal, yarn inventory, gauge and stitch-adjustment calculators, backup and restore, project completion, camera capture, and Traditional Chinese or English UI.

Copy must not claim AI features, cloud sync, automatic stitch recognition, social functions, shopping, or any feature not present in the release build. The paid-listing language may say "one-time purchase" and "no subscription" only while that remains true in App Store Connect.

The primary category remains Lifestyle. Productivity may be used as the secondary category if App Store Connect offers it for the selected platforms.

## Privacy Position

KnitNote 1.0:

- does not require an account;
- does not contain advertising, analytics, or third-party tracking SDKs;
- does not track users across apps or websites;
- does not transmit projects, photos, patterns, yarn data, notes, or backups to a developer-operated server;
- stores working data locally on the user's device;
- creates an external backup only after an explicit user export action;
- accesses the camera only when the user chooses to photograph a project or journal entry;
- accesses imported PDFs, images, and backups only for the user-selected operation.

The App Store privacy questionnaire must therefore declare no developer data collection, subject to a final static and runtime audit confirming that the release contains no network or analytics path.

A `PrivacyInfo.xcprivacy` file must be included in the release target. Before authoring it, the implementation must audit every required-reason API used by the app and its linked code. The manifest declares tracking as false, contains no tracking domains, lists no collected data types, and declares only Apple-approved required reasons that accurately describe the audited local behavior.

## Public Support Site

The support site is a dependency-free static site suitable for GitHub Pages. It contains:

- a bilingual KnitNote overview;
- supported platforms;
- backup and restore instructions;
- camera-permission guidance;
- pattern import guidance;
- a concise troubleshooting section;
- the complete bilingual privacy policy;
- a mail link to `lzz.1999@icloud.com`.

The site uses the same pale blue, lavender, berry, cloud, flower, and Lemon-inspired visual language as the app. It loads no analytics, advertising, cookies, remote fonts, or third-party scripts. It must remain legible with JavaScript disabled and meet basic keyboard, contrast, semantic-heading, and reduced-motion accessibility expectations.

Publishing the GitHub Pages site is an external action. The generated site is reviewed locally first; publication occurs only to the repository and account authorized by the user. The final public HTTPS URLs are then recorded in both metadata files and App Store Connect.

## Screenshot System

The approved screenshot direction is "watercolor story." Real app UI remains the dominant visual element. Pale watercolor clouds, small flowers, and occasional Lemon accents create brand recognition without obscuring controls or text.

All screenshots use a dedicated synthetic demo dataset. They must not include family photos, personal knitting photos, private filenames, contact details, or data copied from a production device.

### iPhone

Five narrative frames show:

1. projects and current progress;
2. six named counters;
3. pattern highlighting with synchronized counters;
4. knitting journal progress records;
5. yarn inventory and knitting calculators.

### iPad

Four frames prioritize the large pattern-reading workspace:

1. maximized full-page pattern view;
2. horizontal and combined highlighting;
3. handwritten markup;
4. page notes and right-side counters.

### macOS

Three frames show large-screen management of:

1. projects;
2. patterns;
3. yarn inventory.

### Apple Watch

Two frames show:

1. selection of an iPhone project and quick counter increment;
2. synchronized access to all six project counters, including offline availability.

Every frame has one short benefit-oriented headline and no dense explanatory paragraph. Traditional Chinese and English sets are generated separately. Exact pixel dimensions follow the current App Store Connect upload slots observed at execution time, and master compositions retain enough safe area to adapt to any required alternate size without covering the UI.

## Release Packaging Audit

The implementation first completes the approved Watch counter synchronization design and validates how the Watch target is packaged. The current project defines `KnitNoteWatch` as a separate application target, so it must be converted or associated using the smallest Apple-supported companion arrangement that embeds or otherwise associates the Watch build with KnitNote while preserving `com.phillon.KnitNote.watch`.

The audit also verifies:

- iOS and macOS Release archives use `com.phillon.KnitNote`;
- the Watch archive or embedded product uses `com.phillon.KnitNote.watch`;
- version and build values are consistent and uploadable;
- all required icons are present;
- camera usage text is localized;
- the privacy manifest is present in every applicable archive;
- exported backup type metadata is valid;
- code signing uses team `9CFPAUL5N5`;
- no unexpected entitlement, framework, network endpoint, or third-party SDK is included.

## Verification

Verification is evidence-based and includes:

1. all Swift package tests;
2. clean Release builds for iOS Simulator, generic iOS device, macOS, watchOS Simulator, and generic watchOS device;
3. signed archive validation for each submitted App Store product;
4. localization contract checks for Traditional Chinese and English;
5. privacy-manifest validation and a source audit for data collection, network access, and required-reason APIs;
6. camera, photo import, PDF import, counter, pattern state, journal, yarn, calculator, project completion, backup, and restore smoke tests;
7. public HTTPS checks for support and privacy URLs;
8. screenshot dimension, language, safe-area, and private-data checks;
9. App Store metadata length and consistency checks;
10. a final App Store Connect comparison against repository source files.

Warnings that affect packaging, privacy, signing, localization, or uploaded assets are release blockers.

## App Store Connect Completion Boundary

The implementation may create and save metadata, privacy answers, screenshots, categories, review contact details, manual-release configuration, and validated build selections in App Store Connect. It may not click the final control that submits either platform version to App Review without a new explicit user instruction after the completed listing is presented for review.

The final handoff reports:

- public support and privacy URLs;
- selected build numbers for iOS, macOS, and Watch;
- completed and outstanding App Store Connect fields;
- validation evidence;
- exact remaining submission action;
- the post-release US$4.99 scheduling procedure.

## Out of Scope

- AI functionality or AI-related marketing claims;
- subscriptions or in-app purchases;
- cloud synchronization;
- analytics, advertising, attribution, or tracking;
- a large marketing website, blog, account system, or newsletter;
- social, marketplace, or commerce features;
- automatic App Review submission without the final user approval.
