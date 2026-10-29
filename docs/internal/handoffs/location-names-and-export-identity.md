# Codex Handoff: Automatic location names and export identity

- Updated: 2026-10-29 (America/New_York).
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch and HEAD: `main` at `413ec2e`.

## Objective

Add Location generates City · latitude, longitude from the actual map centre.
Automatic names track area changes; manually edited names are preserved. Carry
the chosen name into GLB filenames and scene/root names, with full-precision
capture centre, dimensions and variant detail in embedded typed metadata.

## Definition of Done

Naming uses a real coordinate lookup, not stale search text; generated/custom
ownership is explicit and persistent. Lookup errors are explicit. Both textured
and geometry-only exports preserve the identity and geometry. Focused naming,
store, export and current-format tests plus macOS example build pass. Existing
project names and all downloaded/prepared files remain preserved.

## Current Bounded Milestone

Completed the naming/export feature and the separately staged/validated one-time
saved-project update while the app was closed. No live lookup/tile requests,
app launch, commits or pushes.

## Decisions and Constraints to Preserve

- User approved the proposed city + 5-decimal coordinate label and export naming.
- No fallback, legacy reader, alias, automatic migration or old-format branch.
- Persist typed automatic/custom naming in schema 5. Existing schema-4 titles
  must be preserved as custom names in a separate one-time development update;
  no converter ships. Keep backup bytes and validate with the real current store.
- Modern MapKit reverse geocoding / cityName is macOS 26+. Use that single path
  with an explicit unsupported error on older systems, not deprecated CLGeocoder.
  SDK minimum deployment remains 15.6; no build policy changes are needed.
- Use the store's injected city lookup for deterministic network-free tests.
- Resolve automatic names before persisting a moved centre. Preserve later
  manual edits across lookup suspension and MainActor save publication.
- Export identity is a portable SDK value, never an app type. It is an optional
  explicitly selected GLB feature; a declared marker must validate strictly.
- Public package consumers were searched: only the example currently calls the
  GLB exporter. MessScene consumes imported capture geometry through its adapter.

## Repository State

Extensive uncommitted work from this chat and preceding map/preview/export work
must be preserved. `EarthProjectExportService.swift` and its app test are already
untracked current work. Do not stage, commit, push or update submodule pointers.
The app was running as PID 15475 at task start. The user replied **I've closed
MessEarthKit** to the request to close it for the required saved-project update.
Recheck that it remains closed before applying validated unchanged candidates.

## Relevant Files

- `MessEarthKit/MessEarthKit/Storage/EarthLocationRecord.swift`, `EarthProjectRecord.swift`, `EarthProjectStore.swift`, `EarthAppFiles.swift` — typed names, persistence and output names.
- `MessEarthKit/MessEarthKit/Workflow/EarthCityLookup.swift` — coordinate-to-city lookup.
- `MessEarthKit/MessEarthKit/Presentation/EarthProjectViewModel.swift` — Add Location and exact save publication.
- `MessEarthKit/MessEarthKit/Workflow/EarthProjectExportService.swift` — named export composition.
- `Sources/MessEarthKit/API/EarthCaptureIdentity.swift`, `EarthGLBExporter.swift`, `EarthCapture.swift`, `EarthCaptureImporter.swift` — portable identity contract.
- `Sources/MessEarthKit/Tiles/EarthCombinedGLB.swift` — root name / embedded metadata.

## Verification

Initial focused tests passed (5 tests, including two export modes and seven
strict schema cases): `/tmp/messearthkit-location-names-tests.log`. The native
MapKit async-object isolation compile issue was corrected by keeping callbacks
and native objects on MainActor and returning only city strings. No live lookup
has run. Added queued-edit and shared-area-name checks afterward.

The expanded focused run passed 14 tests / 28 cases, including generated/custom
names, delayed manual edits, shared-area refresh, invalid schemas, named
textured/geometry exports, map and existing area/variant checks:
`/tmp/messearthkit-location-names-final-tests.log`. The initial macOS example
Debug build passed: `/tmp/messearthkit-location-names-build.log`.

Saved-project update completed once after the user closed the app. Stage anchor:
`/tmp/mess-earth-location-name-stage.json`; backup/candidate/context/report:
`/var/folders/sh/mlb942gs4rj6bmg888ftszj40000gn/T/mess-earth-location-names-9gzhb64k/`.
Two projects, three locations and four variants were transformed from schema 4
to 5 by replacing only each location title with an explicit custom name.
Python normalized both candidates back to the originals, and the actual Swift
decoder/validation/roundtrip and every source/preparation reference passed.
Original/live/backup hashes matched, the app was confirmed closed, and publication
through EarthAppFiles plus reopening with EarthProjectStore passed. Logs:
`/tmp/messearthkit-location-name-project-validation.log` and
`/tmp/messearthkit-location-name-project-update.log`. Earlier test-only macro
mistakes were corrected before any live write. The temporary validator/updater
has now been removed. Do not repeat the update.

Final importer-name restoration and strict public identity decoding were added
after the initial build. After temporary updater removal, final focused checks
passed: 7 SDK export/metadata tests and 6 app naming/identity tests, including
parameterized export modes, strict schemas and all existing combined-GLB cases.
Log: `/tmp/messearthkit-location-names-delivery-tests.log`. Combined with the
earlier targeted regression run, 21 distinct tests / 42 cases passed. Retained
new checks cover real naming ownership/races and export identity/precision,
without implementation-mirroring UI tests.

The final macOS example Debug build passed without warnings/errors:
`/tmp/messearthkit-location-names-final-build.log`. Scoped diff checks passed.
Formatting lint passes 17 of 19 affected files; pre-existing issues remain in
the view-model line 27 and long export-plan construction lines, outside new
hunks. No broad formatting pass was run. The source scan confirms no temporary
updater, private live paths, old schema reader or compatibility migration ships.

Use the existing centralized MessEarthKit scratch path and normal Xcode
DerivedData. Primary API evidence: local Xcode 27.1 SDK headers and Apple MapKit
documentation for MKReverseGeocodingRequest / MKAddressRepresentations.

## Remaining Issues

Saved-project update is applied and backups are retained. Do not repeat it.
Pre-existing formatting issues remain outside scope. City lookup was compiled
but not exercised against the live service; normal tests used injected cities.
No implementation or verification work remains for this bounded milestone.

## Next Exact Action

Reopen the rebuilt app for user acceptance of automatic city naming. This
milestone is complete and uncommitted. Do not update user projects again.
