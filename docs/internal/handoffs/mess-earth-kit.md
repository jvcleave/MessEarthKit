# Codex Handoff: MessEarthKit capture and export

- Updated: 2026-10-27, 22:26 EDT
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`
- Branch and HEAD: `main`; resolve the planning checkpoint with
  `git log -1 --oneline`.

## Objective

Create a reusable geographic 3D capture package and standalone macOS example app,
following CMResearchKit's ownership model, that prepare portable textured assets
for MessScene. The choice between native GLB support and USDZ export is deferred.

## Definition of Done

A user selects a bounded region/detail target, prepares and previews its geometry,
delivers assets in the selected format, and imports them into MessScene with correct textures,
orientation, and scale. The package works without either application.

## Current Bounded Milestone

Planning is complete. The user authorized committing and pushing the planning
documents. The proposed first implementation milestone remains the native
capture/decode proof described in the initial plan; implementation requires a
later request. Stop/checkpoint after that milestone before beginning the
reliability/UI stages.

## Non-Goals

Source-policy review (the user is handling it separately), MessScene runtime tile
streaming, a custom consumer archive, super-repository/submodule registration,
application implementation, and release/distribution work. Commit scope is the
three planning/reference documents under `docs/internal/`.

## Repository State

The Xcode starter app predates this work and remains untouched and untracked.
The planning checkpoint contains the initial plan, this handoff, and the
user-provided alternative-route reference. The starter app is excluded from the
planning commit. No package, implementation, tests, or dependencies have been
created.

## Decisions and Constraints to Preserve

- Root Swift package plus nested example app; one public module initially.
- Package owns capture/decoding/CPU values/export. App owns credentials,
  destinations, file authorization, UI, scheduling policy, and preview resources.
- Preserve native GLB payloads and required tileset placement metadata. Keep
  decoded CPU assets independent of the eventual serialization/import format.
- Native MessScene GLB support and USDZ export are both candidates. The user
  explicitly deferred that decision; neither format is required for milestone 1.
- Retain the supplied USGS/FEMA/NAIP reconstruction notes as a potential
  alternative route. They do not replace the current capture milestone or choose
  an export format; source/tool details require evaluation if that route is chosen.
- Individual source tiles may not represent an entire region. Assembly and local
  origin handling remain necessary whichever delivery format is selected.
- Local meters: East +X, Up +Y, North -Z; geographic conversion in double precision.
- Prove decoder/compression support, tile placement, and source material fidelity
  before building substantial UI. Evaluate any required writer at the later
  format decision. No runtime external developer tools.
- MessUSDZImportKit currently limits sources to 64 MiB, textures to 4096 pixels,
  and decoded geometry/textures to 256 MiB, with per-mesh/node limits documented
  in its README. Apply those limits if USDZ is chosen; they are not GLB-format or
  universal capture limits. Verify the selected consumer's real resource contract.
- Keep capture credentials/session URLs out of output metadata and diagnostics.
- Keep build intermediates in the centralized MESS-LocalBuilds location.

## Relevant Files

- `docs/internal/plans/MESS_EARTH_KIT_INITIAL_PLAN.md` — staged plan, contracts,
  source findings, first acceptance gate, and source references.
- `docs/internal/research/USGS_BUILDING_RECONSTRUCTION_ALTERNATIVE.md` — preserved
  user-provided alternative-route notes and source links.
- `MessEarthKit/MessEarthKit.xcodeproj/project.pbxproj` — existing app settings;
  reconcile project/target deployment settings during implementation.
- `../CMResearchKit/AGENTS.md` and `../CMResearchKit/README.md` — package/example
  ownership model.
- `../MessUSDZImportKit/README.md` — conditional USDZ consumer contract and
  external `usdz-inspect` validation tool if that format is selected.

## Verification

- Command: staged documentation diff review and `git diff --cached --check`.
- Latest result: exactly three planning/reference documents staged and reviewed;
  `git diff --cached --check` passed. Alternative-route
  notes match the supplied attachment byte-for-byte after the reference preface;
  plan/handoff references resolve. No builds or tests were run for these
  documentation-only changes.

## Remaining Issues

Decoder and final consumer format have not been selected. Actual source
extensions, material semantics, payload size, memory cost, and live API credential
availability must be established during milestone 1. Writer/importer choices
follow at the later format decision. No live-source API call was made here.

## Next Exact Action

When implementation is requested, establish the standalone root Swift package
and a minimal synthetic tiled-GLB decode/placement probe to evaluate the decoder
and immutable CPU asset boundary without choosing a final export format.

**Fresh-task startup:** Read `docs/internal/handoffs/mess-earth-kit.md`, recover
current state from the repository, and continue with its **Next Exact Action**;
read the listed files first, follow directly referenced files or inspect narrowly
adjacent code as needed, and consult the previous conversation only if the
handoff and repository state lack a required decision, constraint, or
authorization.
