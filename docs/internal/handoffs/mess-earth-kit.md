# Codex Handoff: MessEarthKit location workflow

- Updated: 2026-10-29 (America/New_York).
- Owner: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch: `main`, last committed checkpoint `b34a069` (two ahead of origin).
- Current stage is uncommitted; do not commit/push or change Scene/root pointers
  without a new instruction. The prior commit authorization is already fulfilled.

## Objective and current bounded stage

Map completion follow-up: replace the Browse/Cancel Edit control flow with a
visible Done button in Edit Area and Draw Area. Each completed drag still saves
once; Done returns to map panning/zooming and clears map focus. Keep Escape as an
optional unfinished-drag cancellation shortcut, remove it from the map's primary
instructions, and disable Done during an active drag. Implemented and verified:
the macOS example Debug build and scoped diff checks passed. This presentation-only
change adds no behavior-mirroring tests; the unchanged SDK/geometry suites were
not repeated. No app launch, live calls, commit or push. This follow-up is complete.

Completed: direct draft map editing. Add Browse/Edit Area/Draw Area modes,
box dragging, edge/corner handles and rectangle drawing. Map stays north-up and
camera motion is disabled during area editing; transient previews update numeric
fields, commit once on release, and cancel on Escape/navigation. Frozen/busy/stale
locations must reject edits. Use pure projected-geometry/session tests for date-line
wrapping, dimensions, handle crossing and identity/freeze guards, then build the
macOS app. No schema change, paid/live requests, app launch or Export.
Implementation is wired; the 3 new geometry/session tests (7 cases) passed. A
MapKit scale-helper mismatch found by the date-line test was corrected with WGS84
east/north local scales, verified against independent CLLocation distances. New
test source is excluded from the app target. The full app regression gate passed
(21 tests / 48 cases, ~0.69 s), and the first example build passed. The final UI build passed, including keeping failed Draw Area in draw mode,
handles above the outline and graphics clipped to the map pane. Documentation,
source membership and scoped diff/whitespace checks passed. Keep map graphics
separate from app-owned modal overlays. No GUI/live MapKit run is claimed.

Area adjustment follow-up: make recovery discoverable after a no-coverage/incomplete
download. Keep the registered location/source immutable, but put Adjust Area on
incomplete variant cards and frozen-location editor controls. It creates/focuses
an unlocked copy with the exact attempted detail and geometry; no acquisition or
deletion occurs until the user's next explicit action. Verify the copy uses the
target variant's detail rather than the latest/pending detail. Implemented in the
cards/editor with a variant-specific copy action. Focused existing tests passed
(2 tests / 7 cases, ~0.23 s): no-coverage → copy → resize → new source registration
preserves the original journal and enters no automatic retry; copying Preview
while High is the latest retains Preview detail. The initial test compile used an
Equatable-only error macro for a non-Equatable SDK error; explicit case matching
fixed the test without changing the SDK. The macOS example Debug build, scoped
status review and diff/whitespace checks passed. This follow-up is complete.
No schema changes, data conversions or live requests.

Completed address-entry follow-up: a hidden native hosting probe confirms the
grouped form right-aligns SwiftUI TextField values, even with an explicit style.
Spaces reach the model unchanged but trailing whitespace appears delayed. Replace
only address entry with `Presentation/EarthAddressField.swift`, a leading-aligned
native field that preserves equal active editor text/caret and Return-to-search.
The actual control passed a hidden-window entry check for consecutive spaces,
caret advancement, following characters and exactly one Return submission.
The macOS example Debug build and diff checks passed. No schema changes, live
requests, GUI window display or tests that merely mirror this control's layout.
The unchanged package/app suites were not repeated for this presentation-only fix.

Project → Locations → detail variants → whole-region Metal Preview → Export.
The adopted plan is `docs/internal/plans/PROJECT_WORKFLOW_REORGANIZATION_PLAN.md`.
Complete the location model/lifecycle stage and the basic controls needed to use
it. Direct map move/resize/drawing is also complete; Export is the next stage.

Completed and verified, including the approved saved-project preservation:

- Strict project schema **3**, Settings remain **1**. Projects own title, independent
  searchAddress/searchResult, locations, editingLocationID and active capture ID.
- `Storage/EarthLocationRecord.swift` owns an area (center, incomplete Width/Height
  strings), permanent nullable frozenAt, nullable pending variant detail and nested
  variants. All nullable keys are required. Each variant has locationID/detail,
  immutable source request/UUID, creation date and independent preparation.
- First source registration freezes area and pins the variant in one atomic metadata
  mutation **before** Google transfer. It clears pending detail. Pause, failure and
  deleting the last variant never unlock a location. Stored variants must match
  their location's exact geometry. No SDK API or source/prepared format changed.
- Store operations explicitly add/edit/copy locations and add detail variants.
  Copy gets a new ID, no frozen timestamp, variants or prepared/source references.
  Editor writes are keyed by location ID, serialized with title/search writes.
  Source activation for Preview/Resume preserves map search and editor focus.
- Basic UI: search/Update Map is a starting point only. Add Location uses current
  camera center. The location editor offers Name, Width/Height, first/pending
  Variant Detail and Download Tiles. Move to Map Center changes only an unlocked
  area's center; numeric dimensions update its footprint without auto-recentring.
  Location groups contain Show on Map, Copy Location, Add Variant, trash and
  the existing independent variant cards with progress/errors/actions.
- Native confirmed deletion now includes locations. One metadata/file transaction
  detaches all nested variants and trashes their sources/prepared directories.
  Other areas/search/drafts survive. Project/variant deletion and late-save
  protection remain; active work/saves disable deletion.
- Existing project-retained download/preparation/preview lifetimes, revision tickets,
  hidden GPU resource release, offline retry and explicit paid transport remain.
  No app launch, live API/MapKit requests, Keychain writes or export work performed.

## Completed one-time preservation of the existing saved project

The user explicitly replied: **App is closed; preserve and update the project.**
Read-only checks confirmed the exact app process was absent and metadata still
matched the original backup byte-for-byte. The candidate was then applied atomically
through EarthAppFiles, reopened through the real current-format store and verified
against the original title/search/center/dimensions/detail. It is now **schema 3,
one editable location, zero captures**. The temporary helper was removed. The app
intentionally has **no schema-2 reader or automatic migration**.

Read-only inspection found **one schema-2 draft with zero captures**, project ID
`C025F363-A5EE-4DFE-86CF-5FA190AF0868`. Its title, searched address/resolved point,
Width/Height and Detail are retained in a staged schema-3 record with one editable
location. No saved source/prepared reference needs moving or rewriting.

Stage directory:
`/var/folders/sh/mlb942gs4rj6bmg888ftszj40000gn/T/mess-earth-locations-c38gaflo/`

- `original-project.json` — exact original bytes.
- `candidate-project.json` — validated current-format candidate.
- `context.json` — original metadata path and preserved/new identities.
- `/tmp/mess-earth-location-stage.txt` points to the stage.

The candidate passed the actual Swift decoder and store open in an injected
**temporary root**. Its title/search/area/detail were checked against the original.
The temporary validator was removed before final checks. No updater/helper or
private live path is shipped. These stage files are review/backup data, not
runtime fallback locations. `applied.txt` records the successful one-time operation.

Do not repeat the metadata update or add a runtime migration. The backup is retained
outside the repository. No source/prepared artifacts, Settings or usage were changed.
Final headless app verification after helper removal passed: all 18 tests /
40 cases (~1.45 s), with no warnings. Source scan confirms no temporary helper,
update environment variable or private metadata path remains in app/test code.

Storage policy: `docs/internal/architecture/MESS_EARTH_APP_STORAGE.md`.
It forbids runtime legacy readers, migrations, inferred projects, alternate roots
and silent cleanup. An explicit one-time edit does not change that policy.

## Verification

- Passed `swift test --scratch-path "${MESS_BUILD_CACHE_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds}/MessEarthKit/swiftpm" --filter MessEarthKitAppFilesTests`:
  **18 tests**, ~0.79 s. Existing fixtures now cover search/area isolation, concurrent
  title/search/location edits, freeze-before-transport, paused exact-request resume,
  offline preparation, independent copies, same-area detail variants, rejected
  frozen edits, corrupt saved geometry, inactive-file errors, and whole-region
  GPU/publication/navigation checks. Deletion fixtures cover location success/failure
  in addition to existing project/variant scope, rollback, last variant and symlinks.
- A final missing nullable frozenAt case extends the existing invalid-file test;
  that focused test passed **4 cases**, ~0.03 s. Total permanent cases now **40**.
- Temporary one-time candidate validator passed against a fresh injected root;
  it was removed. Initial test compile needed actor values read before a combined
  Testing macro assertion. A redundant optional Testing macro in a fixture helper
  was replaced by an explicit guard. Final checks have no compiler warnings.
- Final macOS example Debug build passed:
  `xcodebuild -quiet -project MessEarthKit/MessEarthKit.xcodeproj -scheme MessEarthKitExample -configuration Debug -destination 'platform=macOS,arch=arm64' build`.
  The new location model/editor compile through existing filesystem-synchronized
  app membership. All six test files remain excluded from the app target.
- SDK sources/contracts unchanged, so the unchanged 52 SDK tests and integrated
  Scene/root build were not repeated. They passed at checkpoint `b34a069`.
- Existing authored source/rendering fixtures remain unchanged. Map editing adds
  one focused geometry/session test file for new projection, resize/cancellation
  and identity risks; no UI-label tests or broad gesture matrices. No broad
  formatting, commit or staging.
- Scoped diff/status review and `git diff --check` passed. No GUI acceptance claim.

## Existing foundations to preserve

- One injected EarthAppFiles owns managed roots, metadata I/O, file authorization
  and Trash. SDK workers retain bounded streaming/hashing/SQLite/payload I/O.
  Project source/prepared/output folders remain UUID-based beneath the project.
- Preserve appearance is default; optimized copies require explicit consent.
  Combined delivery GLB and model-folder exporters exist in the SDK, while the new
  app Export route remains unimplemented. Existing manual workspace adapters are
  unexposed; only the unused restoreProject adapter was removed for the new model.
- Whole-region preview composes all prepared parts in two bounded passes, retaining
  GPU shader values instead of encoded source images. It honors exact shared-origin
  metadata and measured GPU overhead within the admitted budget. Preserve origins,
  placement, materials, attribution and all source/prepared files on preview failure.
- No Core Image additions, diagnostic console writes, process ceiling changes,
  streaming overview claims or source-policy changes belong in this stage.
- App navigation stays in the native stack. Native destructive confirmation is
  explicitly authorized. External export picking remains unresolved; first Export
  can use new project-owned output destinations without a modal picker.

## Next exact action

The location, preservation and map-editing stages are complete; stop here.
On continuation, implement milestone 5 only: whole-variant Export. Inspect the
SDK folder/combined-GLB exporters and preflight plus the unexposed manual export
adapter. Route toolbar Export independently of preview success, offer GLB/folder
and explicit appearance choices, inline progress/errors/reveal and a fresh
project-owned output. Preserve other locations/variants and source artifacts.
External destination picking remains unresolved; no modal picker by assumption.
