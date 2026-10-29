# Codex Handoff: Optional GLB export data

- Updated: 2026-10-29 (America/New_York).
- Owning repository: `/Users/jvcleave/Documents/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch and HEAD: `main` at `413ec2e`; extensive pre-existing uncommitted work.

## Objective

Offer independent normals, vertex colors, UV coordinates, materials and texture
choices for combined GLB export, with Full, Untextured and Minimal presets.

## Definition of Done

Full preserves the current default. Minimal writes positions and triangle indices
with placement, identity and credits. Textures require UVs and materials. Metadata,
binary layout, preflight sizing and the captured app job agree on the choices.
Focused SDK/app export tests and the macOS example build pass.

## Current Bounded Milestone

Completed: optional data end to end in the existing variant exporter.

## Non-Goals

No compression, vertex deduplication, source/prepared-file changes, live requests,
saved-history migration, MessScene changes, app restart, commits or pushes.

## Repository State

Export service/view-model/controls, identity, history and texture omission predate
this task. Scoped originals are in `/tmp/messearthkit-optional-export-baseline`.

## Decisions and Constraints to Preserve

- Checkbox state is scoped to each variant and captured before an export starts.
- Enabling textures enables UVs/materials; disabling either disables textures.
- Existing export history remains schema 1 and retains its texture flag. Detailed
  options are recorded in the exported GLB extras, without changing saved projects.
- Preserve source identity, shared placement, attribution and existing outputs.

## Relevant Files

- `Sources/MessEarthKit/API/EarthGLBExporter.swift` — public job/plan.
- `Sources/MessEarthKit/Tiles/EarthCombinedGLB.swift` — metadata/binary layout.
- `MessEarthKit/MessEarthKit/Workflow/EarthProjectExportViewModel.swift` — options.
- `MessEarthKit/MessEarthKit/Workflow/EarthProjectExportService.swift` — job wiring.
- `MessEarthKit/MessEarthKit/Presentation/EarthProjectExportControls.swift` — controls.
- Existing SDK/app export tests — layout, omissions and captured-job behavior.

## Verification

Implementation is wired through the public options value, plan, binary/metadata
writer, retained variant owner and existing service/UI. Full retains its original
48-byte vertex layout; optional channels reduce the stride down to 12 bytes.
Material omission removes primitive references, definitions and unlit extensions.
Detailed options live in GLB extras; history stays schema 1.

Distinct new risks: optional offsets/stride and byte counts, dangling material/texture
references, retained values and UI dependencies/job capture. Existing fixtures
and export tests are reused; no verification harness or pixel fixture added.

Focused `swift test --filter 'combinedGLB|projectExport'` passed: seven SDK tests
(18 cases) and five app tests (10 cases). These cover each omitted channel,
native-decoder value/topology preservation, exact file size, invalid texture
dependencies, all presets/custom choices and job/cancellation/history behavior.
Log: `~/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds/MessEarthKit/optional-export-tests.log`.
Scoped lint passes all eight Swift files after correcting wrapping in the new
options file. The `MessEarthKit` scheme passed but targets the package; the
affected app must now be built with the shared `MessEarthKitExample` scheme.
The first app-build process received SIGKILL immediately after logging its command,
before dependency resolution/compilation. No compiler error was emitted. Retrying
the app build with `-jobs 2` succeeded, including compilation of the new controls,
service and owner, signing and validation. Its only warning is the ordinary skipped
AppIntents extraction. Log:
`~/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds/MessEarthKit/optional-export-app-build.log`.

Final source/test/doc diff reviewed against the scoped pre-edit snapshots. No
redundant new test fixture/harness or unrelated formatting was introduced. Retained
checks exercise layout/omission, retained geometry, metadata and app job wiring.
Final scoped diff checks pass. Existing histories, raw/prepared sources, user
project files and unrelated uncommitted work are preserved. No app launch/restart,
live request, commit, push or submodule revision change was performed.

## Remaining Issues

None.

## Next Exact Action

This bounded milestone is complete. Relaunch the built MessEarthKit app for GUI
acceptance when convenient; no further implementation/build is required.
