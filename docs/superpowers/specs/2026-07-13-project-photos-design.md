# Project Photos Design

## Goal

Let people attach one optional photo to each knitting project, show it consistently on project cards, and keep the photo available even if the source image is later removed from Photos.

## Scope

- iPhone and iPad support choosing from Photos and taking a new picture with the camera.
- Mac supports choosing an image through the system photo/file picker; direct camera capture is intentionally excluded.
- Creating a project keeps the name as the only required field and allows an optional photo.
- Editing a project supports renaming, replacing the photo, and removing it.
- Project cards show a square cropped preview. Projects without a photo retain the existing lavender placeholder.
- Existing projects and archives remain compatible without migration.

## Storage Architecture

`StoredProject` gains an optional `photoFilename: String?`. The JSON archive stores only this filename, never image bytes or a Photos asset identifier.

`ProjectPhotoFileService` owns photo files beneath the same KnitNote application-support area as the project archive. It accepts image data, decodes and normalizes orientation, scales the longest edge to at most 1600 pixels, encodes a high-quality JPEG, and writes atomically using a unique filename containing the project ID and a new UUID. The service can load and delete a photo.

Replacing a photo writes the new file successfully before updating the model. After persistence succeeds, the previous file is removed. Removing a photo clears the model only after the file operation succeeds. Deleting a project also deletes its photo; a missing file is treated as an already-complete cleanup.

## Model and Store Behavior

- `StoredProject.photoFilename` defaults to `nil` during creation and decoding.
- The custom decoder uses `decodeIfPresent`, so archives created before this feature load unchanged.
- `JSONProjectStore.add(name:photoData:)` creates the project, saves an optional normalized photo, then persists the model.
- `JSONProjectStore.updateProject(id:name:photoChange:)` handles rename-only, replace-photo, and remove-photo operations without changing row, note, or pattern state.
- A failed photo operation leaves the previous project model and previous photo intact.
- Archive version increments from 5 to 6, while decoding remains backward compatible.

## User Interface

### Creation

`CreateProjectView` adds a photo preview above the name field. An action menu offers “Choose Photo” on every platform and “Take Photo” on iPhone and iPad when a camera is available. The photo remains optional. The existing validation and cancel/save behavior are preserved.

### Editing

The existing rename sheet becomes `EditProjectView`. It loads the current name and photo, supports replacement or removal, and performs one save operation. Cancel discards staged name and image changes.

### Project Cards

`ProjectCard` receives a photo URL or decoded platform image through a small reusable `ProjectPhotoView`. The preview uses a fixed square frame and aspect-fill clipping. If loading fails or no filename exists, it displays the current lavender placeholder without showing an error in the list.

### Platform Capture

- `PhotosPicker` handles photo-library selection where available.
- An iOS-only camera wrapper presents the system camera interface and returns image data.
- Camera actions are hidden when the device reports no camera.
- Mac uses the system picker and does not request camera permission.
- The iOS target includes a localized camera usage description in Traditional Chinese and English-compatible project metadata.

## Localization and Accessibility

Add Traditional Chinese and English strings for choosing, taking, replacing, and removing photos; photo-processing errors; and the project-photo accessibility label. Photo previews describe the project photo rather than decorative styling. Menus and removal actions retain standard button traits, and removal is not communicated by color alone.

## Error Handling

- Unsupported or corrupt image data produces a localized save error.
- Camera cancellation and picker cancellation make no data changes and show no error.
- File-write or archive-persistence failure preserves the previously committed photo and project state.
- Missing photo files fall back to the placeholder and can be replaced normally.

## Testing

- Model decoding verifies version-5 archives without `photoFilename` still load.
- File-service tests cover valid save, deterministic size limits, replacement, deletion, and invalid data.
- Store tests cover create with photo, replace, remove, project deletion cleanup, and rollback after a failed photo write.
- Existing row, note, pattern, markup, and localization tests must remain green.
- Manual acceptance covers iPhone camera, iPhone Photos, iPad camera/Photos, Mac picker, Dynamic Type, replacement, removal, relaunch persistence, and placeholder fallback.

## Non-Goals

- Multiple photos per project.
- Photo editing, filters, manual crop controls, captions, or albums.
- Mac camera capture.
- iCloud photo synchronization or shared-project synchronization in this iteration.
