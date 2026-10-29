# Codex Handoff: Manual Wireframe preview

- Updated: 2026-10-29 (America/New_York).
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch and HEAD: `main` at `413ec2e`; extensive existing uncommitted work.

## Objective

Download completion leaves navigation alone. The user opens Preview explicitly,
initially in Wireframe. Resolve the supplied saved capture's budget rejection.

## Definition of Done

Remove the download navigation callback; retain the explicit Preview action.
Set default preview display to Wireframe. Establish the actual memory cause and
verify an appropriate fix with focused renderer/workflow checks, the saved
capture where feasible, and the macOS app build.

## Current Bounded Milestone

Completed: manual preview entry, Wireframe default, and device-scaled memory
admission, verified with focused regressions and the full saved capture.

## Non-Goals

No source/prepared-file changes, reacquisition, geometry reduction, persistence
format changes, fallback paths, commits, app launch, or Google configuration.

## Repository State

Download navigation callback removed; explicit Preview entry retained, including
entry during preparation. Preview view model/service/loader now default to
Wireframe. Automatic uses half Metal's recommended working set without a fixed
1 GiB ceiling. Custom budget input is shown only when Automatic is disabled;
errors point to custom Budget or Model Parts. Existing geometry, device and
upload-headroom checks remain. Existing tests updated for the changed defaults.

## Decisions and Constraints to Preserve

- User explicitly forbids fallback or legacy code.
- Previous Automatic policy used min(1 GiB, half Metal's recommended working set).
  Current policy uses half that recommendation and retains all admission checks.
- Hardware RAM: 64 GiB. Supplied prepared collection is ready and complete,
  with 40 models, 11,448,627 estimated vertices/indices and 1,603,534,848 decoded
  base-level texture bytes. Wireframe forecast: 780,168,076 bytes with
  34,065,628 bytes for the largest part; 3,245 meshes, 64-byte vertex stride.
  This forecast fits the old limit. Actual scene allocation: 812,141,380 bytes
  (~775 MiB); final device allocation: 812,613,632 bytes.
  Metal recommends 55,662,788,608 bytes, giving 27,831,394,304 automatic bytes.
- Saved source: project `274115F5-21F8-4A1D-89C2-92D969802D41`, source
  `FF95C0DE-4D2F-4A84-A35C-3B10FF27213A`, prepared
  `CBF2EF85-36DB-4716-AE9D-A6C8D1C819D4`, under Documents/MessEarthKit/projects.
- Reads of that source/prepared capture are offline; retain all original files.
- Keep existing allocation, viewport and per-part upload headroom checks.

## Relevant Files

- `MessEarthKit/MessEarthKit/Presentation/EarthProjectLibraryView.swift` — navigation.
- `MessEarthKit/MessEarthKit/Presentation/EarthProjectViewModel.swift` — download/preparation.
- `MessEarthKit/MessEarthKit/Workflow/EarthRegionPreviewViewModel.swift` — display default.
- `MessEarthKit/MessEarthKit/Workflow/EarthPreviewMemoryLimit.swift` — admission limit.
- `MessEarthKit/MessEarthKit/Rendering/EarthRegionPreviewLoader.swift` — two-pass admission/upload.
- `MessEarthKit/MessEarthKit/Workflow/Tests/EarthRegionPreviewTests.swift` — existing renderer/lifecycle checks.

## Verification

- Saved-capture headless upload diagnostic passed: all 40 models / 3,245 meshes,
  no textures or samplers in Wireframe. Both an explicit old 1 GiB budget and
  the new Automatic budget succeeded in a fresh test process. The exact previous
  running-app failure was not reproduced; existing allocations count toward
  admission and the new policy allows more headroom on this Mac. Log:
  `/tmp/messearthkit-preview-capture-upload.log`.
- Initial exploratory forecast-only diagnostic rejected its assumption that the
  forecast already exceeded 1 GiB; no production regression failed.
- Temporary diagnostic test removed; its source copy remains outside the repo
  at `/tmp/messearthkit-saved-preview-probe.swift`. Source/prepared catalog reads
  are offline/read-only. No acquisition, app restart or user-data update.
- `swift test --scratch-path <centralized MessEarthKit/swiftpm> --filter
  'regionPreview|projectCompletionCannotStealNavigation'`: passed, 8 tests / 17
  cases. Retained checks cover device-scaled limits, actual allocation admission,
  full-region placement/materials, texture-free rendering, cancellation/source
  identity, default Wireframe, display switching/release and async navigation.
  No new permanent tests/fixtures or redundant assertion sets were added. Log:
  `/tmp/messearthkit-manual-wireframe-preview-tests.log`.
- macOS example Debug build passed. Log:
  `/tmp/messearthkit-manual-wireframe-preview-build.log`.
- `git diff --check` passed. Scoped lint passes 6/9 touched Swift files; existing
  unrelated violations remain at view-model line 27, service lines 58–59, and
  preview-test lines 108/143/208. Log:
  `/tmp/messearthkit-manual-wireframe-preview-lint.log`.

## Remaining Issues

The exact memory rejection was not reproduced in a fresh process. Live GUI
acceptance remains pending; the existing running app has not been restarted.

## Next Exact Action

Relaunch the updated app for GUI acceptance when the user is ready. This bounded
implementation milestone is complete; no further source work is required.
