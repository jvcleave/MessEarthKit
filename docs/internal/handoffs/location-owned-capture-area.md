# Codex Handoff: One capture area per location

- Updated: 2026-10-29 (America/New_York).
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch and HEAD: `main` at `413ec2e`.

## Objective

Adjust Area edits a location's shared capture box. Applying updates every pending
variant together while retaining each variant's detail and stable identity. A
location with any retained completed capture requires Copy Location for a new box.

## Definition of Done

Current variant requests all match their location's box. Begin/apply reject any
completed current or historical source; stale drafts cannot overwrite newer
variant/location state. Apply Area stays offline and atomically publishes all
replacement source references, retaining old downloads/journals and other
locations. Detail, download, deletion and map-draft behavior remain coherent.
Focused app tests and the example macOS Debug build pass.

## Current Bounded Milestone

Completed: replaced variant area adjustment with a location draft and atomic batch
update, updated the UI/coverage, and verified. No SDK changes, schema migration,
live requests, app launch, saved-user-data edits, commits or pushes.

## Repository State

Extensive uncommitted map/preview/export/storage work and previous chat changes
must be preserved. The old `EarthVariantAreaAdjustment.swift` is untracked task
work and will be replaced by `EarthLocationAreaAdjustment.swift`.

## Decisions and Constraints to Preserve

- User explicitly approved location-owned boxes and detail-only variants.
- Apply Area updates all pending variants offline; Download remains on each card.
- Completed source files, including retained earlier attempts, block area changes.
- Keep every old source attempt in previousCaptures; no source/journal rewrites.
- Structural project fields stay unchanged. Read-only audit of the two current
  projects / three locations found zero mixed-area locations and no parse errors;
  no user-data update is needed.
- Do not add a compatibility path for independent variant boxes.
- User reiterated explicitly: do not add fallback or legacy code. The former
  type/methods and variant retry UI are removed, with no aliases or migrations.

## Relevant Files

All paths below are within `MessEarthKit/MessEarthKit/`:

- `Workflow/EarthLocationAreaAdjustment.swift` — shared edit snapshot.
- `Storage/EarthProjectStore.swift`, `EarthLocationRecord.swift` — atomic area updates and validation.
- `Workflow/EarthProjectCaptureService.swift` — source registration/transfer.
- `Presentation/EarthProjectViewModel.swift`, `EarthLocationEditorView.swift`, `EarthProjectCapturesView.swift`, `EarthProjectLibraryView.swift` — draft/apply/download wiring.
- `Workflow/Tests/EarthProjectCaptureTests.swift`, `Storage/Tests/EarthProjectDeletionTests.swift` — behavior regression coverage.

## Verification

Implementation is in place: location-owned draft and store apply, all-current
area validation, completed-history eligibility, offline Apply Area UI, and
removal of variant-specific adjustment/retry. Updated existing workflow/deletion
fixtures and added a shared-area regression plus current/historical completion
race cases. Distinct risks: all-variant atomicity and detail preservation,
completed/stale rejection, source-history retention and deletion ownership.

Initial scoped lint found one new blank line, corrected. The pre-existing view
model line-27 blank-line issue remains outside scope.

Passed focused app checks: 8 tests / 23 cases covering shared-area changes,
stale/current/historical completion rejection, offline registration and transfer,
detail locking, frozen requests, and deletion/history rollback. Log:
`/tmp/messearthkit-location-owned-area-tests.log`. Retained assertions address
distinct state, ownership, area-consistency and source-preservation risks.
The macOS example Debug build passed without warnings/errors:
`/tmp/messearthkit-location-owned-area-build.log`. Scoped source/UI review and
`git diff --check` passed. Eleven changed Swift files pass formatting lint; the
pre-existing view-model line-27 blank-line issue remains untouched. The source
scan confirms the old variant adjustment type/methods and retry UI are gone.

## Remaining Issues

Existing unrelated formatting issues remain outside scope. No GUI acceptance
is claimed. No implementation or verification work remains for this milestone.

## Next Exact Action

Use the rebuilt app's location-level Adjust Area / Apply Area, then Download on
each pending variant. This milestone is complete and uncommitted.
