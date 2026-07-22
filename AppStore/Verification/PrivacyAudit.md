# KnitNote Privacy Manifest Audit

Last updated: 2026-07-23

## Result

KnitNote does not send developer-accessible user data off device and includes no account, advertising, analytics, telemetry, tracking domain, network client, or third-party SDK. Both privacy manifests therefore declare no tracking and no collected data types.

## Main app declarations

### File timestamp — `C617.1`

The project, yarn, pattern, journal, and backup services inspect file type, size, and descriptor metadata inside KnitNote's Application Support and temporary work directories. This is app-container file metadata used to validate, persist, reconcile, export, and restore user-created knitting data.

### File timestamp — `3B52.1`

The backup restore and pattern import paths validate file or directory metadata for URLs the user explicitly selects through system file pickers. This access is limited to the selected document or package and supports import and restore behavior visible to the user.

### User defaults — `CA92.1`

`KnitNote/App/KnitNoteApp.swift` uses `@AppStorage("languageSelection")` to persist the language selected inside KnitNote. The value is app-local and is not read from or shared with another app or service.

## Watch declaration

### File timestamp — `C617.1`

The Watch executable contains the shared atomic local-file and validated persistence implementation used for its application-container synchronization cache. The release binary imports `fstat` and `fstatat`; no user-selected external document flow is available on Watch, so `3B52.1` is intentionally not declared there.

The Watch app does not access `UserDefaults`; its snapshot, queue, and selection state use versioned files in Application Support. It therefore does not declare the User Defaults category.

## Source and binary audit

- Required-reason source search covered `UserDefaults`, `@AppStorage`, `stat`, `fstat`, file date keys, disk-space APIs, and system uptime APIs across `KnitNote`, `KnitNoteWatch`, and `Sources/KnitNoteCore`.
- Release-binary undefined-symbol inspection confirmed file-stat APIs in both executables and AppStorage/UserDefaults only in the main app.
- Network and SDK search covered `URLSession`, Network framework connections, Firebase, analytics, telemetry, tracking, and literal HTTP(S) endpoints. No runtime network or third-party SDK path was found.
- Camera and user-selected photos remain local app functionality and are not transmitted to the developer.

## Approved-reason references

The reasons were checked against Apple's current Required Reason API documentation on 2026-07-23: `C617.1` for app-container file metadata, `3B52.1` for metadata of user-granted files or directories, and `CA92.1` for app-only user defaults.
