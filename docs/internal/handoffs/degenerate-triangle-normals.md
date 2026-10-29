# Codex Handoff: Degenerate triangle normal recovery

- Updated: 2026-10-29 (America/New_York).
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch and HEAD: `main` at `413ec2e`.

## Objective

Recover usable geometry when flat-normal generation encounters zero-area source
triangles, without discarding downloads or hiding omitted geometry.

## Definition of Done

Normals are calculated in double precision before output-position rounding.
Only truly zero-area triangles are omitted; no-usable-geometry and malformed
content errors remain explicit. Omission counts survive subdivision and combined
GLB export. Focused regression checks and the macOS example build pass.

## Current Bounded Milestone

Completed: decoder correction and omission accounting as one SDK change. No
commits, live requests, app launch, or saved-user-data changes.

## Repository State

The repository already has uncommitted app preview/export/workflow work and SDK
texture-free-export changes. Preserve these, especially existing edits in
`EarthCombinedGLB.swift`, `EarthGLBExportTests.swift`, `README.md`, and the main
handoff. No decoder edits existed at task start.

## Decisions and Constraints to Preserve

- User explicitly authorized the suggested correction after discussion.
- Source archives remain immutable. Preparation/export write separate artifacts.
- Do not infer degeneracy from rounded output positions or an absolute epsilon.
- Expose numeric omission diagnostics; do not invent normals for zero-area faces.
- Use the existing centralized MessEarthKit SwiftPM scratch directory.

## Relevant Files

- `Sources/MessEarthKit/Tiles/EarthGLBDecoder.swift` — flat normals and validation.
- `Sources/MessEarthKit/API/EarthCapture.swift` and `EarthCaptureImporter.swift` — capture accounting.
- `Sources/MessEarthKit/Tiles/EarthGeometrySubdivision.swift`, `EarthDerivativeGLB.swift`, and `EarthCombinedGLB.swift` — durable diagnostics.
- `Tests/MessEarthKitTests/EarthCaptureImportTests.swift` — targeted decoder regressions.
- `Tests/MessEarthKitTests/EarthModelPreparationTests.swift` — existing archive helper.

## Verification

- Implementation is in place. Flat normals use source-space Double cross
  products and inverse-transpose transforms, avoiding translations entirely.
  Exactly zero source cross products are omitted, with incremental output-budget
  enforcement. Supplied-normal behavior is unchanged.
- Numeric counts are exposed on captures, carried once across subdivided source
  parts, aggregated across placements and combined exports, and included in the
  integration probe. No app UI text or logging dependency was added.
- Added focused analytic import regressions and one archive → subdivision →
  combined-GLB roundtrip using existing fixture/archive infrastructure. Distinct
  risks are degeneracy classification, precision, reflection/winding, invalid
  content, omission accounting and source immutability.
- Passed focused `flatNormals`, omission preparation/export roundtrip and existing
  standalone-import checks: 6 tests (including three analytic precision cases),
  log `/tmp/messearthkit-degenerate-tests.log`. Raw source bytes are verified
  unchanged. Scoped SwiftFormat lint (9 files) and `git diff --check` passed.
- Passed existing import/Draco/subdivision/export regressions: 16 tests including
  authored, flat-normal, reflected-UV and compressed subdivision/roundtrips,
  sampler/source validation, cancellation and admission checks. Log:
  `/tmp/messearthkit-degenerate-regressions.log`. This overlaps the new omission
  roundtrip once; total coverage is 21 distinct tests across both focused runs.
- Passed macOS example Debug build with normal Xcode DerivedData. Log:
  `/tmp/messearthkit-degenerate-build.log` (no warnings/errors).
- Reviewed scoped source/test diffs and retained only distinct regression risks.
  Existing unrelated edits remain intact. No broader suite or workspace build
  is required for this component-local additive change.

## Remaining Issues

The actual failing user payload has not been inspected or retried. Analytic
regressions independently cover genuine degeneracy and precision loss. Final
render positions remain Float; this change fixes normal-generation precision
without changing the renderer's coordinate/storage contract.

## Next Exact Action

Relaunch the rebuilt example app and retry preparation from the existing source
download. No further implementation stage is pending for this bounded fix.
