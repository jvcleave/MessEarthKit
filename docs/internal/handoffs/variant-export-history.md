# Codex Handoff: Variant export controls and history

- Updated: 2026-10-29 (America/New_York).
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch and HEAD: `main` at `413ec2e`; extensive uncommitted work predates this task.

## Objective

Move export controls onto each variant. Persist every successful export with its
variant, source/preparation IDs and texture choice, and restore it after reopening.

## Definition of Done

Preview has only viewing controls. Variant export targets that exact card,
independent of selected preview, and prepares offline if necessary. Cards show
history, Show in Finder for present files, and explicit Export Again. Cancellation
and failure do not create false successful history or damage existing outputs.
Focused app storage/export regressions and the macOS example build pass.

## Current Bounded Milestone

Completed: variant-owned export actions and persistent history, including
offline preparation, explicit re-export and failure/cancellation behavior.

## Non-Goals

No SDK/public contract changes, format migration, legacy code, source reacquisition,
automatic adoption of untracked outputs, destructive cleanup, app restart or commits.

## Repository State

Existing project-scoped Export view model/service save unique GLB files but retain
only the latest URL in memory. Preview contains the controls. All prior edits,
including manual Wireframe preview and current project schema 5, must be preserved.

## Decisions and Constraints to Preserve

- Export history is independent strict version-1 `exports.json` metadata per
  project, absent before the first successful tracked export. Existing project
  records stay schema 5; absence is the initial history state. Corruption errors
  explicitly and is never replaced with empty history.
- Records store variant/source/preparation identity, immutable export identity,
  texture choice and a managed output file reference. AppFiles owns paths/I/O.
- Preserve earlier untracked output files; do not infer their variant ownership.
- Existing variant deletion retains outputs. Historical provenance does not
  require original source/prepared files to remain after explicit deletion.
- New export attempts always use new output UUIDs and preserve previous exports.
- Never silently treat a completed file with failed history persistence as a
  successful tracked export; report the retained output explicitly.

## Relevant Files

- `Storage/EarthAppFiles.swift` — metadata and output-file operations.
- `Storage/EarthProjectStore.swift` — explicit variant source/preparation validation.
- `Workflow/EarthProjectExportService.swift` — offline export and history publication.
- `Workflow/EarthProjectExportViewModel.swift` — variant job/option/history state.
- `Presentation/EarthProjectCapturesView.swift` — variant cards.
- `Presentation/EarthProjectExportControls.swift` — export controls.
- `Presentation/EarthProjectPreviewView.swift` — remove exports from this view.
- `Workflow/Tests/EarthProjectExportTests.swift` — existing local export fixture.

## Verification

Implemented strict history records/store and AppFiles output metadata, explicit
`openVariant` and variant-targeted preparation recording, offline export/preparation,
variant-scoped job/options/history UI and Finder validation. Preview export controls
removed. Project initialization/refresh loads history. Late history-save failure
reports and retains an unrecorded completed GLB. No project schema changes.

Focused export checks passed: 4 tests / 7 cases, covering
inactive-variant routing, exact identity/materials, cancellation, offline
preparation, persistent separate histories, repeated exports, unavailable files,
strict corrupt-history rejection and explicit retention after metadata failure.
Log: `/tmp/messearthkit-variant-export-tests.log`. Tests use local temporary
fixtures and preserve raw/prepared data. New argument formatting follows the
existing policy.

Shared source/preparation consumers passed all 36 app storage/workflow tests;
macOS Debug build passed. Final review caught a failure-refresh risk to pending
editor values. Completion now adopts editor metadata only when no pending edits
or persistence error remain. One final focused check that a failed edit save
blocks export before source lookup/output creation passed, and the final app
build passed. Total: 37 distinct app tests across targeted runs, including five
export tests / eight cases. Retained tests cover distinct routing/provenance,
appearance, lifecycle, corruption and retention risks; no UI-presence tests,
duplicate fixtures or redundant assertion sets were added.

- Shared app tests: `/tmp/messearthkit-variant-export-app-tests.log`.
- Final save gate: `/tmp/messearthkit-variant-export-save-gate-test.log`.
- Final build: `/tmp/messearthkit-variant-export-build.log`.
- Scoped lint: `/tmp/messearthkit-variant-export-lint.log`; 12/14 files pass.
  Existing view-model line 27 and preview-test lines 108/143/208 are unchanged.
  Final export-test lint passes. `git diff --check` passes.
- Updated app:
  `/Users/jvcleave/Library/Developer/Xcode/DerivedData/MessEarthKit-aaxlsglcoqbipfacwbmjmwentehf/Build/Products/Debug/MessEarthKit.app`.

All work remains uncommitted. No actual user project files, schema versions,
source/prepared data or Google settings were changed; no app restart was performed.

## Remaining Issues

No implementation blockers. Live GUI acceptance remains pending app relaunch.
Earlier untracked output files remain on disk without inferred variant ownership.

## Next Exact Action

Relaunch the updated app for GUI acceptance when ready. This bounded milestone
is complete; no further implementation or builds are required.
