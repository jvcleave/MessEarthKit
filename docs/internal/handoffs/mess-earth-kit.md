# Codex Handoff: MessEarthKit location workflow

- Updated: 2026-10-29 (America/New_York).
- Owner: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.
- Branch: `main`; implementation checkpoint `587de16`, published with record
  `08459c8`. Current user authorization is to update, commit and push the
  simplified README. Leave MessScene, SDK pins and root pointers alone.

## Objective and current bounded stage

Current documentation task (2026-10-29): user approved updating, committing and
pushing an app-first README, ordered requirements → Google key → project →
capture → preview → export → consuming output files. Move detailed contracts,
existing package examples and verification notes into a linked technical
reference; defer redesigning SwiftPM guidance. Starting HEAD is `08459c8`, clean
and synchronized with origin/main. Source confirms current Add Location requires
macOS 26 city lookup despite a 15.6 deployment target. Verify Google key steps
against official docs. Documentation-only: inspect diff/links; do not build.

Documentation result: README reduced from 794 to 135 lines with exactly the
seven agreed sections. Detailed contracts, existing SDK examples and verification
notes live in `docs/TECHNICAL_REFERENCE.md`, with corrected relative links. The
stale MessScene limitations paragraph and future-app-export statement were
removed/replaced. Google setup, restrictions and billing were checked against
official Google documentation; local flow labels were checked against source.
Seven-section order, ten relative links, code fences, diff and whitespace checks
passed. No builds/tests or runtime/source changes. SwiftPM redesign is deferred.

Publication checkpoint: `origin/main` fetched and still matches `413ec2e`.
Reviewed the completed SDK/export, app workflow/preview and storage changes and
their task handoffs. Commit all current EarthKit source, tests and documentation
as one coherent checkpoint after scoped staged-file formatting, existing focused
checks and the macOS example build. No new feature work, user-data changes or live
requests belong to this publication task.

Publication verification: all 49 staged Swift files pass parent-config lint;
four needed mechanical formatting. Staged diff checks passed. Final batch gate
passed 21 focused SDK tests plus all 37 app storage/workflow/preview tests.
Logs: `/tmp/messearthkit-publish-lint.log`, `/tmp/messearthkit-publish-tests.log`.
The affected macOS example build result is recorded below.

Publication app gate passed: arm64 Debug `MessEarthKitExample` with `-jobs 2`,
normal Xcode DerivedData, signing enabled; exit 0 and empty log at
`/tmp/messearthkit-publish-app-build.log`. Final staged whitespace/status review
passed, with no unstaged source edits. Implementation commit `587de16` completed
successfully. No app launch, user-data writes, live requests or other repository
changes were made during publication.

Completed bounded milestone: optional GLB normals, vertex colors, UVs, materials
and textures with Full, Untextured and Minimal presets in the variant exporter.
Binary layout, preflight size and output metadata follow captured per-variant
choices; textures require UVs/materials. Twelve focused tests (28 cases), scoped
lint/diff checks and the macOS example Debug build passed. Existing saved-history
schema, user data and unrelated work are preserved. No app restart, live request
or commit. Details: [`optional-glb-export-data.md`](optional-glb-export-data.md).

Completed bounded milestone: variant cards own Export GLB/Export Again, texture
choice, progress/Cancel and persistent history with validated Finder actions.
Exports target the clicked variant, prepare offline if needed and preserve editor
and preview selection. Strict schema-1 `exports.json` records successful exports
beside unchanged schema-5 `project.json`; old untracked outputs are not adopted.
Five export tests / eight cases, all 36 then-current app component tests and the
final macOS Debug build passed. The final save-failure gate was checked separately
after preserving pending edits during completion refresh (37 distinct app tests
across targeted runs). Diff checks passed; 12/14 touched Swift files pass lint,
with existing unrelated violations in two files left intact. No live app restart,
user-data writes, acquisition, migration, fallback, commits or pushes. Details:
[`variant-export-history.md`](variant-export-history.md).

Completed bounded milestone: downloads keep the current screen; the explicit
Preview button opens the viewer, initially in Wireframe. Automatic uses half
Metal's recommendation without the fixed 1 GiB cap; aggregate/actual-allocation
checks remain. The supplied saved Chicago capture loaded all 40 models in
Wireframe, using 812,141,380 GPU bytes (~775 MiB). It also fit the old limit in a
fresh test process, so the exact running-app rejection was not reproduced.
Focused regressions (8 tests / 17 cases), the macOS example Debug build and diff
checks passed. Existing lint issues outside edited lines remain. Temporary
private-path diagnostic source is removed; data remains intact. No app restart,
live requests or commits. The running app must be relaunched to load changes.
Details: [`manual-wireframe-preview.md`](manual-wireframe-preview.md).

Completed small display follow-up: hide Reveal Download until the variant archive contains
at least one completed payload, including retained partial downloads. An empty
offline source journal no longer shows the action. Scoped lint/diff checks and
the macOS example Debug build passed; log:
`/tmp/messearthkit-reveal-downloaded-files-build.log`. No new tests were needed.
Changes remain uncommitted.

Completed small display follow-up: variant titles now contain only the detail level,
without repeating the location's width/height. Updated the existing title
property and README; no state/schema/export changes. Scoped lint/diff checks
and the macOS example Debug build passed; log:
`/tmp/messearthkit-variant-detail-title-build.log`. No new tests were needed.
Changes remain uncommitted.

Completed bounded milestone: Add Location generates city/coordinate names at the
actual map centre, automatic names refresh on area changes, and manually edited
names are retained. GLB filenames include the sanitized location name/detail;
scene/root names and typed identity retain the chosen name and full-precision
capture request. Focused naming/store/export/map regressions and final macOS
Debug build passed (21 distinct tests / 42 cases across targeted runs). Existing
unrelated formatting issues remain untouched. After the user confirmed closing
the app, two saved projects / three locations / four variants were updated once
to schema 5 with original titles preserved as custom names and backups retained.
The staged candidate/reference validation and real-store reopen passed. Temporary
update helpers are removed; no legacy reader, fallback or automatic migration
ships. No live lookup/tile requests, app launch, commit or push. Detailed results:
[`location-names-and-export-identity.md`](location-names-and-export-identity.md).

Completed bounded milestone: one shared capture box per location. Adjust Area
edits that box, and Apply Area updates all pending detail variants offline in one
metadata save. Retained completed captures lock the area; use Copy Location.
All source histories and stable IDs are preserved. The old per-variant adjustment
path is removed with no fallback, legacy reader, alias or migration. Focused app
checks (8 tests / 23 cases), macOS example Debug build and diff checks passed.
Eleven changed Swift files pass lint; the existing view-model line-27 issue is
untouched. Current saved projects were audited read-only and contain no mixed
areas. No app launch or saved-user-data edits. Detailed results:
[`location-owned-capture-area.md`](location-owned-capture-area.md).

Completed small UI follow-up: moved Adjust Area out of variant cards to directly below
Height in the location editor. A single eligible incomplete variant is targeted
directly; multiple eligible variants get an explicit menu choice. Cancel
Adjustment occupies the same row while editing. Existing request/history and
retry behavior is unchanged. Scoped lint/diff checks, the existing adjustment
workflow check and the macOS example Debug build passed. Logs:
`/tmp/messearthkit-adjust-area-location-test.log` and
`/tmp/messearthkit-adjust-area-location-build.log`. No new tests, app launch or
saved-user-data changes. All changes remain uncommitted.

Completed small UI follow-up: moved Copy Location out of each variant card and the empty
draft's separate row into the location header, next to Show on Map. It copies
the location's area/default detail through the existing action. Scoped lint/diff
checks and the macOS example Debug build passed; log:
`/tmp/messearthkit-copy-location-header-build.log`. No new tests were needed.
Changes remain uncommitted.

Completed bounded UI/workflow follow-up: Detail is on each saved variant card,
editable before any acquisition attempt and fixed afterward. Location controls
own name/area and Add Variant. Request consistency, source histories and stable
IDs are preserved with the existing schema. Focused workflow checks (5 tests /
14 cases), the final edited-request transfer test and macOS example Debug build
passed. Scoped diff checks passed; pre-existing unrelated lint issues remain.
Detailed results: [`variant-owned-detail.md`](variant-owned-detail.md). No GUI
launch, live requests, saved-user-data edits, commits or pushes.

Completed small UI follow-up: removed the date/time line from saved variant
cards and updated the README. Scoped lint/diff checks and the example Debug
build passed; log: `/tmp/messearthkit-remove-variant-date-build.log`. No new
tests were needed for this presentation-only removal. Changes are uncommitted.

Completed small UI follow-up: combined the standalone Location editor and
repeated location summary into one named section per location. The selected
location contains its setup controls, then a Variants label and saved cards.
Other locations retain Show on Map, summary, copy and deletion access. No models,
storage, jobs or download behavior changed. Scoped lint (3 files), diff review,
`git diff --check` and the macOS example Debug build passed. Build log:
`/tmp/messearthkit-location-section-build.log`. No new tests, app launch, live
requests or saved-user-data edits. Changes remain uncommitted.

Completed bounded milestone: Add Variant registers and freezes a saved area/detail
offline. Download is below Copy Location on each saved variant and explicitly
targets that variant. Current schemas, source histories and existing work are
preserved. Focused workflow/store/navigation checks (6 tests / 15 cases), the final
registration regression, macOS example Debug build and diff checks passed. Existing
unrelated lint issues remain untouched. No GUI launch or live Google requests.
Detailed results: [`variant-registration-before-download.md`](variant-registration-before-download.md).

Completed small UI follow-up: removed Move to Map Center from the location editor
and its unused view-model action, and removed the README reference. The macOS
example Debug build and diff checks passed; log:
`/tmp/messearthkit-remove-map-center-build.log`. The editor view passes scoped
lint. View-model lint reports a pre-existing missing blank line at line 27,
outside this edit; left unchanged. No package behavior changed or new tests were
needed. Changes remain uncommitted.

Completed bounded follow-up: recover zero-area source triangles during flat-normal
generation and preserve double precision through normal calculation. Raw downloads
remain intact; omission counts survive derived/combined GLBs and appear in the
integration probe. New focused checks, existing import/Draco/subdivision/export
regressions (21 distinct tests total), scoped lint/diff checks and the macOS
example Debug build passed. Detailed results and logs:
[`degenerate-triangle-normals.md`](degenerate-triangle-normals.md). The actual
failing capture has not been retried. Changes are uncommitted, and pre-existing
preview/export/workflow work is preserved. No app launch or saved-user-data edits.

Completed bounded milestone: Textured / Solid without textures / Wireframe without
textures in the project Preview. Default Textured preserves appearance. Capture
the chosen mode once per job, include it in preview reuse identity and reload on
mode changes. Geometry modes allocate no source/fallback textures or samplers,
exclude textures from admission estimates and use neutral solid/wire shaders
without image sampling; geometry, viewport and measured-allocation checks remain.
Release the displayed renderer scene before replacement. Keep the same full
geometry, bounds, shared placement and credits for whole/part previews. The
choice is session state and does not change exports, prepared/source files or
schemas. Done means focused GPU allocation/rendering checks and existing job/
cache/lifecycle coverage pass, plus the macOS example build. No SDK/Scene changes,
live requests, user-data updates, GUI launch, commit or push.

Mode loading/rendering is implemented. All seven focused regionPreview tests
passed, including texture-free resource estimates/uploads, the actual offscreen
renderer drawing wireframe with less filled coverage than Solid, and mode
snapshot/cache/lifetime checks in the existing publication test. That check holds
the old renderer alive and verifies its scene is released on mode replacement.
Existing textured sampler/mipmap/placement, allocation and source/cancellation
checks remain. After the final edit, the publication test (five lifecycle cases)
and macOS example Debug build passed without warnings. Diff checks passed. Logs:
/tmp/messearthkit-preview-modes-tests.log,
/tmp/messearthkit-preview-modes-publication.log and
/tmp/messearthkit-preview-modes-build.log. No GUI acceptance is claimed. Changes
remain uncommitted; this milestone is complete.

Completed bounded milestone: optional texture-free GLB export. There is an explicit
includeTextures choice to offline GLB preflight/plan/binary writing (default true),
project only geometry costs when omitted, and leave downloaded/prepared sources
untouched. Retain normals, UVs, colors, material factors, coordinates and credits;
omit embedded images and their texture/sampler references. Expose Include textures
and Export GLB on the current project Preview, exporting every prepared part via
a retained MVVM owner, source/access validation, cancellation and a fresh project
output folder through EarthAppFiles, with Show in Finder. This honors the current
no-overlay navigation policy without a native save panel. Use GLB container/index/metadata bounds for standalone
delivery rather than imposing the per-part preview profile on the combined file.
Done means a texture-free roundtrip with unchanged geometry and no image payload,
textured default regression coverage, one app wiring/lifetime check, and example
macOS build. No live Google requests, source/settings schema edits, Scene changes,
GUI launch, commit or push. Google's documented API provides no texture-off query;
this is an offline output choice and does not reduce downloaded tile bytes.

Five focused SDK export tests passed, including texture omission and default
textured roundtrips. The app owner/service test passed: whole-region output
without a GPU preview, captured texture choice, unchanged project/preparation
metadata and cancellation cleanup retaining an earlier successful export. The
test canonicalizes macOS /var aliases. Its source is excluded from the Xcode app
target beside the existing headless tests. Final macOS example Debug build and
diff checks passed. Logs: /tmp/messearthkit-texture-free-export-tests.log,
/tmp/messearthkit-texture-free-app-tests-final.log and
/tmp/messearthkit-texture-free-export-build-final.log. No GUI acceptance is
claimed. All changes remain uncommitted; stop before the full Export screen.

Completed bounded milestone: adjustable preview memory, before streaming/LOD work.
Automatic/custom GiB controls are directly on the project preview with Reload
Preview. The retained preview owner holds the preference for this app session;
no settings/project schema or saved-user-data update is needed. Automatic keeps
min(1 GiB, half Metal's recommendation); custom is an explicit byte limit that
overrides that policy while keeping upload/reserve/measured-allocation checks.
Invalid/overflowing input blocks new loads without silently using Automatic or
discarding the displayed preview. The chosen limit is captured once per job and
included in preview reuse identity. The six focused regionPreview tests passed:
unit/overflow validation, existing admission/allocation checks, scene composition
and cancellation/source lifetime, plus changed-budget worker/cache coverage in
the existing publication test. The macOS example Debug build and diff checks
passed after the final source edit. No GUI acceptance is claimed. No Scene/SDK change, live requests, app
launch, whole-large-region allocation, commit or push. Large-capture part import
and preview work is complete in the root handoff earth-large-capture-workflow.md.

Completed bounded milestone: Adjust Area edits an incomplete variant in place.
Keep project/location/variant IDs and counts, preserve sibling source snapshots,
and record each adjusted retry as a fresh source attempt under the same variant.
Retain earlier archives in explicit metadata history, including confirmed deletion
ownership. Keep edits as a cancellable owner-held draft until Retry Download;
never start transfer from Adjust Area. Schema 4 separates stable variant IDs
from source IDs; current-format-only readers remain strict. Implement/test before
preparing a concrete one-time saved-project update for user approval. The user
has now explicitly replied **Apply the saved-project update** to that exact
candidate. Initial checks confirm the app is closed and live metadata/candidate
hashes match the staged review. The update has now been applied once through
EarthAppFiles and reopened through the real store; the temporary helper is
removed. Do not repeat the metadata update. Do not launch the app, use live
Google transport, commit or push. The user interrupted
the proposed GUI check with this correction; no GUI session/app was started.

Implementation is complete. The 23 permanent app tests passed; no-coverage and
detail-unavailable checks now assert one unchanged variant/location identity,
fresh source ownership, unchanged original journal bytes and no automatic retry.
The sibling/stale/completed-source check passed. Existing deletion cases now
exercise revised source IDs, prior-attempt cleanup and rollback. Initial test-only
compile/macro mistakes were corrected; ordinary Copy Location keeps its exact
numeric editor strings when the source matches its area. The SDK is unchanged.

Applied, backup retained: `/tmp/mess-earth-variant-revision-stage.txt` identifies
`/var/folders/sh/mlb942gs4rj6bmg888ftszj40000gn/T/mess-earth-variant-revision-9uxxdp9w/`.
It contains the original bytes, candidate and context/hash records for the one
known current saved project (one location/one variant). The transformation changes
only version 3 → 4 and adds each variant's stable ID/empty previousCaptures.
All other decoded fields were compared unchanged. The actual current decoder,
validation, roundtrip and read-only source/preparation-reference checks passed
through a temporary test, now removed. After explicit approval, the app-closed
and unchanged-original checks passed again; the exact candidate was atomically
written through EarthAppFiles. EarthProjectStore.open and every variant's status
reopened successfully, with unchanged location/variant counts and source/prepared
requests. Only project.json changed; source/prepared artifacts, Settings and usage
were untouched. The approved one-time helper passed and was removed.
Final app regression checks after helper removal passed (23 tests), as did the
macOS example Debug build and diff checks. Source-level work is complete; the
one-time saved-project update is complete. No updater, private live path or
compatibility reader ships. Final normal app tests after helper removal passed
(23 tests, ~0.81 s), as did diff checks and the source scan for temporary updater
content/private live paths. `applied.json` records the successful operation in
the stage directory; original backups remain. No app-source change required
repeating the earlier app build. This milestone is complete and uncommitted.

Completed follow-up: keep the existing MapKit footprint visible and make an unlocked
box directly editable, removing the separate Edit Area button. Native polygon
rendering must not depend on selection/drawing state. Limit the edit hit region
to the box/handles so map browsing remains available outside it; retain Draw Area
and Done. Project pointer/handle positions in a shared named map coordinate space
and refresh them with camera, viewport and area changes. The focused map tests
passed (4 tests / 8 cases): new screen targeting covers direct movement, visible
handle precedence and outside-box browsing; retained tests cover wrapped geometry,
cancel/stale/frozen sessions and invalid drawing. The example Debug build passed.
Final review bounds the interaction frame to the map pane so oversized/offscreen
areas cannot intercept surrounding controls; the final Debug build and diff
checks passed. No visual GUI acceptance is claimed. No schema/SDK change, live
map/API requests, app launch, commit or push.

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

The simplified README and linked technical reference are complete. Commit and
push these three documentation files on main, then verify remote HEAD and a
clean tree. Stop before revising SwiftPM guidance; that discussion is deferred.
Leave MessScene, package pins, super-repository pointers and user data unchanged.
