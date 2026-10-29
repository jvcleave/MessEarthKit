# Codex Handoff: Variant-owned detail controls

- Updated: 2026-10-29 (America/New_York).
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch and HEAD: `main` at `413ec2e`.

## Objective

Move the detail picker from the location editor to each saved variant card.
Location editing owns name/area and Add Variant; detail can change only before
any attempt for that variant has entered acquisition.

## Definition of Done

Detail changes persist offline and retain stable variant/location IDs, sibling
snapshots, editor selection and all original source journals. Download consumes
the revised request. Started/prepared variants reject detail changes. Focused
workflow checks, scoped lint/diff review and macOS example Debug build pass.

## Current Bounded Milestone

Completed the variant detail edit as one app-only change, using existing
source-attempt history and the project schema. No migration, SDK journal rewrite,
live requests, app launch, user-data edits, commits or pushes.

## Repository State

Extensive uncommitted map/preview/export/storage work and previous fixes from
this chat must be preserved. View/model/store files already have unrelated edits.

## Decisions and Constraints to Preserve

- Subsequent shared-area work supersedes the former per-variant area adjustment:
  [`location-owned-capture-area.md`](location-owned-capture-area.md). Detail remains
  per variant; every current variant now uses its location's capture box.
- A new variant inherits its existing location default/copy detail; the card owns
  the picker. The location no longer presents a detail option.
- Changing an unused detail creates a fresh empty source attempt and keeps the
  original journal in previousCaptures. Earlier attempt details can differ;
  each current variant detail must still match its current request exactly.
- Check every recorded attempt before allowing detail changes, including an
  empty current retry whose earlier attempt already downloaded/failed.
- Keep API keys and transport out of detail editing.

## Relevant Files

- `MessEarthKit/MessEarthKit/Presentation/EarthLocationEditorView.swift`
- `MessEarthKit/MessEarthKit/Presentation/EarthProjectCapturesView.swift`
- `MessEarthKit/MessEarthKit/Presentation/EarthProjectViewModel.swift`
- `MessEarthKit/MessEarthKit/Storage/EarthProjectStore.swift`
- `MessEarthKit/MessEarthKit/Storage/EarthProjectCaptureVariant.swift`
- `MessEarthKit/MessEarthKit/Storage/EarthProjectRecord.swift`
- `MessEarthKit/MessEarthKit/Workflow/Tests/EarthProjectCaptureTests.swift`

## Verification

Implemented the picker move and retained source-attempt mutation. Extended the
existing offline registration test for repeated detail changes, exact download
request, stable IDs and retained original journal/siblings/editor. Added one
table-driven lock test for in-flight, paused, completed and earlier-started
attempts; it verifies no metadata or artifact mutation on rejection.

Passed the focused workflow/store checks: 5 tests / 14 cases, log
`/tmp/messearthkit-variant-detail-tests.log`. Scoped lint found new picker/factory
layout, now corrected; existing unrelated formatting issues remain. Extended the
existing test to transfer the edited request explicitly, in addition to older
variant selection; the final affected check passed:
`/tmp/messearthkit-variant-detail-final-test.log`.

The macOS example Debug build passed with no warnings/errors:
`/tmp/messearthkit-variant-detail-build.log`. Scoped source/UI diff review and
`git diff --check` passed. Retained tests address distinct ownership/request,
source-preservation and acquisition-lock risks, with no UI-presence tests.

## Remaining Issues

Existing unrelated formatting issues in the view model, store and adjustment
test remain outside this change. No GUI acceptance is claimed. No implementation
or verification work remains for this bounded milestone.

## Next Exact Action

Use the rebuilt app's per-variant Detail picker before Download. No further
implementation stage is pending; all changes remain uncommitted.
