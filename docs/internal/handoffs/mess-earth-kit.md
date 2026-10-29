# Codex Handoff: MessEarthKit project workflow

- Updated: 2026-10-29 (America/New_York).
- Owner: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch: `main`; prior checkpoint `6689abd`. The new checkpoint is the commit
  containing this handoff and the approved location plan; resolve it with `git log`.

## Objective

Projects → Project Details (title/capture editor + MapKit) → selected capture's
whole-region 3D Preview → Export, plus global Settings. Projects retain multiple
capture variants; one selected variant supplies each preview/export operation.
Retain working sources and prepare/export offline. Adopted plan:
`docs/internal/plans/PROJECT_WORKFLOW_REORGANIZATION_PLAN.md`.
Next approved extension is **Project → Locations → detail variants**; current
source remains the schema-2 project/capture implementation described below.

## Current Bounded Milestone and Definition of Done

The user authorized committing all current MessEarthKit work and recording the
agreed location flow. The plan now prioritizes the location extension before
Export: map search is a starting point, Add Location creates an editable area,
first acquisition registration freezes it, variants change only Detail, and Copy
Location creates an independent unlocked draft. Frozen locations stay frozen
after variants are removed. This turn implements none of that future model.
Checkpoint gate: scoped staged Swift formatting, all existing package/app tests,
macOS example build, staged diff review, then commit Earth only. Do not update
Scene/root/submodule pointers, push, launch the app or rewrite user project data.
Commit-time formatting passed: 83 staged Swift files scoped to the workspace
configuration (41 changed mechanically). The formatter reported deprecated rule
names in that existing configuration; its policy was preserved. Scoped lint
passed (0/83 need formatting). The full package test gate passed after formatting:
52 SDK tests (~14.78 s) plus 18 app tests (~0.83 s), no failures. The first
post-format app build surfaced a return/closure indentation warning in the usage
observer getter; an explicit typed local observer retains its behavior and avoids
that ambiguity. The final macOS example Debug build passed cleanly after that
clarification. All checkpoint gates and staged diff checks passed. This handoff,
the approved plan and current Earth implementation are saved together by the
authorized Earth-only checkpoint commit; the unchanged SDK/app test sources
needed no repeated run.

Completed icon follow-up: installed the user's Desktop/OUTPUT/macOS/AppIcon.appiconset in
the example app's existing Assets.xcassets/AppIcon.appiconset. All ten macOS PNG
slots have matching dimensions, and copied files/Contents.json match the supplied
bytes. Both build configurations already select AppIcon. The macOS example Debug
build and diff checks passed; no additional package tests for this asset-only edit.

Completed: confirmed project/variant deletion. Home rows (including listed unreadable
projects) and variant cards have accessible trash buttons. Native destructive
confirmations are explicitly requested exceptions to the no-overlay rule.
EarthAppFiles moves managed files to macOS Trash. Project deletion includes its
whole UUID folder and waits for queued saves; later writes cannot resurrect it.
Variant deletion serializes metadata, preserves other variants/editor/settings,
retains shared prepared references and rolls back normal Trash failures. Removing
the active variant chooses the last remaining variant; removing the last leaves
a usable draft. Active work/saves disable deletion; file mutation cannot be cancelled.

All 18 app tests / 37 cases passed (~0.69 s), including failure rollback, scoped
files/global-state retention, late-write protection and symlink rejection. The
macOS example Debug build passed. New deletion tests are in
`Storage/Tests/EarthProjectDeletionTests.swift`, excluded from the Xcode app target.
Fixtures inject a temporary Trash directory; actual user data and Trash were
untouched. No app launch, live-service call, schema change, commit or Export work.

Completed: independent variant cards replace Selected Capture, selection badges
and Use Capture. Each card owns status, Reveal in Finder, Preview or Resume
Download, Restore Capture Area, progress/cancellation and errors. Preview/resume
activate the exact saved source while preserving the editor/map; only Restore
Capture Area replaces those settings. Reveal resolves the card's own source
through the files boundary without activating it. Navigation tickets and one
active pipeline remain. The 3D toolbar identifies its variant in the subtitle.
Journal-only status reads do not load models or write metadata. Per-card revisions
prevent late reads replacing newer live results. New draft detection checks all
saved requests so previewing another variant cannot invent a draft.

All 16 app tests / 31 cases passed (~0.48 s), including extended existing fixtures
for draft/map preservation, frozen resume requests and unavailable-card isolation.
The final macOS example Debug build passed, including explicit card button styles
and late-status guards. No schema changes, migrations, live requests or Export.

Completed follow-up: changing detail/area immediately shows a New variant draft
(for example Preview → High). Download Tiles saves it; the retained selected saved
capture's detail/dimensions identified what View Preview opened. Matching a saved
request removes the draft row. Acquisition stays explicit and project schema 2
is unchanged. Existing app tests passed (16 tests / 31 cases, ~0.45 s), and the
macOS example Debug build passed. No new tests mirror the small presentation edit.

Previous presentation follow-up completed: source reveal buttons now read Reveal
in Finder; the example Debug build and diff checks passed.

**Completed: independent project titles, capture variants and Download Tiles.**
The title is separate from the address, auto-saves and supplies list/navigation
labels. Capture variants coexist with frozen area/detail/location/request and
independent prepared references. Download Tiles remains beneath Update Map.
Card Preview validates/reopens a variant offline; Restore Capture Area explicitly
restores its editor/map, including for the internally active variant.
Original source/prepared files and other variants are retained on every outcome.

All 16 app tests / 31 cases and the final macOS example Debug build passed.
Existing current project metadata was updated once with explicit user approval;
its existing capture and prepared model reopened successfully. Final source
membership/docs/whitespace/status review passed. Stop before Export.

## Implementation and Ownership

- `Storage/EarthProjectRecord.swift` uses strict schema **2**. Required fields are
  independent title, draft, nullable resolvedLocation, capture array, nullable
  selectedCaptureID, IDs/dates. Current capture/preparation are computed from the
  selected variant; no duplicate persisted pointers. Empty titles display Untitled
  Project without changing the address. Settings remain schema 1.
- `Storage/EarthProjectCaptureVariant.swift` freezes capture identity/request,
  editor draft, nullable location and creation date, and owns a nullable preparation.
  Validation rejects duplicate IDs, missing/unknown selection, mismatched frozen
  dimensions/detail/location and wrong capture/preparation identity. Nullable keys
  must be present. The app has no schema-1 project reader or automatic migration.
- `EarthProjectStore` serializes atomic title/draft edits without losing unrelated
  fields. New acquisitions append/select a variant before Google transport.
  Activation validates the target before committing and preserves draft/location
  unless explicit Restore Capture Area requests their replacement. It retains
  all other preparations. Bad inactive files cannot displace a valid
  current selection. Preparation/acquisition still reject a non-selected source.
- `EarthProjectViewModel` coalesces pending title/draft saves and retains project
  job ownership. Selection/refresh waits for pending edits. A committed selection
  is adopted if cancellation arrives during its atomic write; newer editor values
  are preserved and cancelled jobs do not start another preview.
- `Presentation/EarthProjectCapturesView.swift` owns the independent variant
  cards/actions. The library prepares/renders only the currently visible active
  capture. Renderer identity recreates the native Metal surface on replacement,
  even if SwiftUI batches a scene reset and reload.
- One `EarthAppFiles` owner supplies Documents/project/source/prepared/output
  locations, bounded atomic metadata I/O, confinement/SQLite-sidecar checks and
  access leases. SDK workers retain bounded streaming/hashing/catalog I/O.
- Global Settings owns Keychain and usage. Only explicit Download Tiles/Resume
  enters acquisition. Lookup/map/rename/switch/refresh/preparation are independent
  of Google transport. Credentials never enter project/settings JSON.

## Approved Existing-Project Metadata Update

The user explicitly answered: **App is closed; preserve the existing project.**
A candidate schema-2 record was staged and validated against the current recorded
source/prepared files. The app-closed check and original-byte comparison preceded
an atomic write through EarthAppFiles. The current record reopened with the same
source UUID/request and prepared UUID/profile: **one capture, one prepared model**.
The independent initial title preserves the old visible project name. Editor
values were retained; the captured snapshot uses the frozen acquisition request.
No source/prepared artifact was moved, rewritten, deleted or newly discovered.

Original metadata backup:
`/var/folders/sh/mlb942gs4rj6bmg888ftszj40000gn/T/mess-earth-title-variants-npcjyez5/original-project.json`.
The same directory retains the staged candidate/context for review. These are
metadata reports outside the repository, not runtime fallback locations. The
one-time validator/update helper and its private paths/env/prints were removed
from test source. Do not repeat this operation on startup or ship an old reader.

## Existing Workflow and Preview Foundations

- Project Details has controls on the left and MapKit always visible on the right.
  Update Map/address Return resolves inline; dimension/detail edits redraw the
  current request. Editing the address/invalid dimensions clears the footprint.
  Camera motion is camera-only. Cached matching saved locations reopen offline.
  Date-line wrapping and explicit polar/large map-display limits do not cap sources.
- Source journals are initialized offline and pinned before transport. Pause/
  resume uses exact recorded identity. Source success automatically prepares
  offline; navigation revision tickets prevent late completion stealing focus.
  Back never cancels jobs. Sources survive preparation/preview failure.
- Whole-region preview uses two bounded model passes, no aggregate CPU capture or
  combined GLB. GPU materials retain shader values instead of encoded source images.
  It preserves origin/placement/materials/sampling/alpha/attribution, unions bounds,
  and frames both viewport axes. Hidden scenes release GPU resources; workers finish
  independently and hidden completion is discarded for later offline reopen.
- The importer now honors exact validated messEarthKitSharedOrigin metadata;
  recomputing from ECEF caused a false sourceChanged error away from the equator.
  Ordinary external tilesets derive their frame from bounds. Real identity checks
  remain strict. Refresh Project/Preview rereads saved references before retrying.
- Preview budget is min(1 GiB, half Metal's recommended working set), including
  existing allocations, full scene, largest upload/mipmap headroom and 64 MiB
  viewport reserve. Heap-query values are forecasts; measured overhead updates
  the remaining-scene projection before re-admission. Actual device use remains
  checked. The old actual<=forecast guard falsely rejected a ~64 MB saved region;
  that region passed the corrected read-only GPU probe (one model, 67 meshes).
  This is GPU admission, not process/native-crash isolation.
- Earlier SDK work is complete: request ledger, streamed acquisition/resume,
  incremental prepared catalogs, geometry/base-level texture subdivision, explicit
  optimized copies, source matching and folder/combined-GLB exporters. Do not
  restart these stages while completing the remaining app flow.

## Decisions and Constraints

- Follow the project workflow plan and `docs/internal/architecture/MESS_EARTH_APP_STORAGE.md`.
  Filesystem policy stays in the app-files owner; no MessScene app imports or
  whole-payload app Data wrappers. Project metadata stays bounded and atomic.
- No runtime legacy readers, migrations, inferred projects, alternate-root searches,
  automatic old-ledger reuse or cleanup. The approved one-time metadata edit above
  does not create ongoing compatibility policy or orphan-folder adoption.
- Preserve appearance is default. Optimized copies require explicit permission and
  recorded provenance. Never silently drop/downsample/weld parts or switch formats.
- Coordinates are meters, East +X, Up +Y, North −Z; retain Double through shared
  origin subtraction. No new Core Image, direct console or OSLog diagnostics.
- Keep one acquisition/preparation/preview/export pipeline active initially;
  project navigation remains available. Request/source/selected-variant identity
  and resource/access lifetime stay independent of screen lifetime and title edits.
- App screens use navigation/toolbar Back, with native project/variant deletion
  confirmations explicitly permitted by the user. Other app-owned modal overlays
  remain excluded. Native
  external destination picking remains unresolved. Initially write exports to new
  project-owned output directories and reveal them; do not assume a modal exception.
- No live API/MapKit requests, app launch, runtime Keychain write, Cloud/Scene/root
  changes, native ceiling increases, deletion, commit or push were performed here.
  Source-policy review, exact cross-crop mip/normal delivery, stronger native
  isolation and arbitrary-size streaming remain separate scopes.

## Repository State and Relevant Files

The checkpoint includes all current Earth SDK, app, tests, icons and planning work
since `6689abd`, including earlier SDK and scheme changes. Earlier authorized checkpoints were Earth `6689abd`, Scene
`83b333c3`, root `5cc90e5`; they were not pushed by that checkpoint task. This stage
changed Earth only. Old unexposed manual workspace helpers still compile; final
acceptance/cleanup owns their removal. There is no legacy primary-UI route.

Under `MessEarthKit/MessEarthKit/`, start with `Storage/EarthProjectRecord.swift`,
`EarthProjectCaptureVariant.swift`, `EarthProjectStore.swift`, `EarthAppFiles.swift`;
`Presentation/EarthProjectViewModel.swift`, `EarthProjectLibraryView.swift`,
`EarthProjectDetailView.swift`, `EarthProjectCapturesView.swift`; and the existing
`Workflow/` capture/navigation/region-preview owners and `Rendering/` resources.
Tests compile actual app storage/workflow/rendering through the internal
`MessEarthKitAppFilesTests` target; all five test files are excluded from the app.

SDK Export contracts: `Sources/MessEarthKit/API/EarthGLBExporter.swift`,
`EarthCaptureStore.swift`, `EarthPreparationProfile.swift`, `EarthPreparedCollection.swift`.
The old `Presentation/EarthModelExportView.swift` is an adapter to inspect, not the
new Export route. Existing native limits are recorded in
`docs/internal/plans/NATIVE_PREPARATION_BOUNDARY.md`.

## Verification

- Confirmed deletion follow-up: all 18 tests / 37 cases passed, plus the macOS
  example Debug build with native confirmation and trash-button wiring. Two new
  parameterized tests reuse existing source/preparation fixtures and an injected
  temporary Trash operation: project scope/global-state preservation and late-save
  protection; inactive/active/last variant behavior, metadata/file rollback and
  escaping symlink rejection. No UI-label tests or duplicate media fixtures.
- Latest card follow-up: existing app test fixtures additionally cover journal
  status reads without metadata changes, independent unavailable cards, activating
  both completed/paused variants without replacing draft/resolved map/title,
  explicit restore, and resuming a frozen High request while the draft is Preview.
  These extend distinct lifecycle risks in existing tests; no duplicate fixtures
  or UI-label tests were added. All 16 tests / 31 cases and the final example
  Debug build passed. No GUI acceptance or live service calls were performed.
- Passed: `swift test --scratch-path "${MESS_BUILD_CACHE_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds}/MessEarthKit/swiftpm" --filter MessEarthKitAppFilesTests`.
  **16 tests / 31 cases**, final ~0.44 s after temporary-helper removal.
  Title/draft/location concurrent edits retain all fields. Preview/Standard cases
  cover completed/paused variants, independent preparation, reopen/switch/restore,
  stale acquisition/preparation rejection, raw identity preservation and bad
  inactive variants leaving selection untouched. Existing schema/confinement,
  GPU placement/material/mip/admission/cancel/navigation checks remain green.
- The one-time metadata candidate validated read-only, then atomically applied and
  reopened with actual current artifacts. A nested Testing macro in the temporary
  helper needed splitting before execution; no data write occurred on that compile
  failure. The helper was removed before final tests/build.
- Passed: `xcodebuild -quiet -project MessEarthKit/MessEarthKit.xcodeproj -scheme MessEarthKitExample -configuration Debug -destination 'platform=macOS,arch=arm64' build`.
  Final build includes Restore Capture Area and native renderer replacement identity.
  No compiler output. Normal DerivedData and stable centralized SwiftPM scratch
  paths were reused. No SDK contract/format changed, so no unchanged full SDK or
  integrated Scene build was rerun.
- Passed: generated source membership (new model/view included, all four tests
  excluded), final document links/status, whitespace and scoped Git status review.
  No GUI acceptance was performed.

## Next Exact Action

This verification/commit checkpoint is complete; stop here. On continuation,
start the first bounded stage of the approved **locations/detail-variants** plan:
typed location identity, independent map-search and capture-area state, durable
draft/frozen lifecycle, freeze before first transport, detail-only variants and
independent copy semantics. Review the plan's Next approved milestone section and
current Store/Record/owner code before changing schemas. Preserve actual source/
prepared artifacts; no runtime legacy reader or automatic migration. Complete
and checkpoint that model/lifecycle stage before map gestures/new location UI.
Whole-variant Export remains milestone 5 after this extension.
