# Project Detail Photo Design

## Goal

Replace the repeated small project name in the project detail screen with the project's photo.

## Approved Design

- Keep the large project name at the top of the detail screen.
- Replace the second centered project-name label with a centered 96 by 96 point rounded-square `ProjectPhotoView`.
- Read the image from `store.photoURL(for: project)` so edits appear automatically.
- When no photo exists, use the existing `ProjectPhotoView` watercolor placeholder and yarn icon.
- Keep the counter row immediately below the photo and preserve the watercolor styling.

## Verification

- A source contract verifies that `ProjectDetailView` uses `ProjectPhotoView` and `store.photoURL(for: project)` before the counter row.
- The contract verifies the 96 by 96 frame and rounded clipping.
- Existing project photo and counter tests continue to pass.
