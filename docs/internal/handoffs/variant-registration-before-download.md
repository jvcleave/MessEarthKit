# Codex Handoff: Save variants before downloading

- Updated: 2026-10-29 (America/New_York).
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch and HEAD: `main` at `413ec2e`.

## Objective

Replace the location editor's Download Tiles action with Add Variant. Add Variant
saves the exact area/detail offline and freezes the first location area. Each
saved variant owns Download directly below Copy Location, plus pause/resume/retry.

## Definition of Done

Adding a variant requires no API key or transport, survives reopening with a
Not downloaded status and leaves a separate immutable request for every variant.
Download targets the requested card regardless of editor/active selection. Existing
adjustment history, offline preparation, navigation, source preservation and
deletion remain intact. Focused app checks and macOS example build pass.

## Current Bounded Milestone

Completed this registration/transfer split using the current project format and
existing offline paused-source registration. No schema migration,
live requests, saved-user-data edits, app launch, commits or super-repo changes.

## Repository State

There is extensive pre-existing uncommitted preview/export/map/storage work,
plus the completed normal-generation fix and Move to Map Center removal from
this chat. Preserve all of it; consult scoped diffs before editing.

## Decisions and Constraints to Preserve

- Subsequent UI/workflow follow-up moves the detail picker onto each saved
  variant, with offline changes allowed only before acquisition. See
  [`variant-owned-detail.md`](variant-owned-detail.md) for current behavior.
- User approved area/detail snapshotting and location freezing at Add Variant.
- Keep acquisition and preparation separate; creation never calls transfer.
- Keep API-key requirements on Download/Resume/Retry only.
- Use a card's saved variant ID for download and copy actions.
- A nullable pending detail is valid current-format state; after registration,
  the next detail selection defaults to the latest variant's detail.
- SDK source archives already support offline paused registration with zero
  source requests. No new persisted state or format version is needed.

## Relevant Files

- `Presentation/EarthLocationEditorView.swift`, `EarthProjectCapturesView.swift` — controls.
- `Presentation/EarthProjectViewModel.swift`, `EarthProjectLibraryView.swift` — retained jobs and explicit variant selection.
- `Workflow/EarthProjectCaptureService.swift` — registration/transfer boundary.
- `Storage/EarthLocationRecord.swift`, `EarthProjectStore.swift` — detail defaults and statuses.
- `Workflow/Tests/EarthProjectCaptureTests.swift` — source/selection/lifecycle checks.

Paths above are below `MessEarthKit/MessEarthKit/`.

## Verification

- Implementation is in place. Add Variant registers offline via the existing
  service; library Download selects an explicit saved variant and only transfers.
  Retry commits an adjusted source under its existing variant ID. Source/card
  status distinguishes zero-request archives from started downloads.
- The location Detail picker remains available after registration, defaulting to
  the latest saved detail when the nullable pending selection is cleared. The
  obsolete store operation that only opened a detail draft was removed.
- Added one existing-infrastructure workflow check for reopen without transfer,
  snapshot freezing, explicit older-variant activation, no extra variant on
  download and preservation of an unrelated editor draft. No UI-presence tests.
- Passed focused workflow/store/navigation checks: 6 tests / 15 parameter cases,
  including the new offline-registration/explicit-variant transfer check. Log:
  `/tmp/messearthkit-variant-registration-tests.log`.
- Scoped lint found new test argument layout, now corrected. Existing lint
  issues remain outside the new hunks in the view model, store retry method and
  pre-existing adjustment test; do not format unrelated work.
- Passed macOS example Debug build using normal Xcode DerivedData, with no
  warnings/errors: `/tmp/messearthkit-variant-registration-build.log`.
- After removing redundant new assertions and correcting new test formatting,
  the final offline-registration/explicit-variant check passed again:
  `/tmp/messearthkit-variant-registration-final-test.log`.
- Final scoped source/UI diff review and `git diff --check` passed. New UI/action
  references are consistent; no Download Tiles action remains in this flow.
- Follow-up after the user's screenshot: the repeated draft summary and separate
  Location editor were confusing. They now appear as one section per location,
  with the selected location's setup controls followed by a Variants label and
  saved cards. Show on Map selects other location editors. Scoped lint and the
  example Debug build passed; `/tmp/messearthkit-location-section-build.log`.

## Remaining Issues

Pre-existing lint issues remain outside the new hunks in the view model, store
retry method and adjustment test. No actual app GUI acceptance is claimed.
No implementation or verification work remains for this bounded milestone.

## Next Exact Action

Use the rebuilt app's Add Variant, then the saved card's Download. No further
implementation stage is pending; all changes remain uncommitted.
