# Project Completion Design

## Goal

Let knitters explicitly mark a project as finished without losing counters, notes, patterns, photos, or history.

## User Experience

- Add a project status section at the bottom of Edit Project.
- An active project shows a prominent `Mark as Completed` action.
- Completing records the current date as `completedAt` and closes the edit screen after saving.
- A completed project shows `Completed` and its completion date in Edit Project, plus a `Resume Project` action.
- Resuming clears `completedAt` and restores counter interaction.
- Project cards remain in the existing list and show a compact `Completed` badge. The project is not moved or hidden.

## Completed Project Behavior

- Preserve all six counter names and final values.
- Disable tap-to-increment and long-press counter management in Project Detail.
- Disable the six counter controls in Pattern Reader.
- Keep photo, notes, patterns, page navigation, highlights, markup, and reading available.
- Display a visible completed status near the project photo in Project Detail.
- Editing project metadata and resuming remain available.

## Data Model and Persistence

- Add optional `completedAt: Date?` to `StoredProject`.
- Existing archives decode with `completedAt == nil`, so all existing projects remain active.
- Include `completedAt` in encoding without changing or discarding existing project data.
- Add one store operation that sets completion and one that resumes the project.
- Counter mutation methods refuse to change values for completed projects, providing a second safety layer behind disabled UI.

## Localization

Add Traditional Chinese and English strings for:

- Project status
- In progress
- Completed
- Mark as completed
- Completed date
- Resume project

## Verification

- Model tests cover completion date persistence, blocked counter mutation, and resuming.
- Store tests cover save/reload of completed state.
- Source contracts cover Edit Project actions, completed badges, and disabled counters in both Project Detail and Pattern Reader.
- Existing archives and existing project functionality continue to pass the full test suite.
