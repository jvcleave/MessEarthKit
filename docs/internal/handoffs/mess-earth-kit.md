# Codex Handoff: MessEarthKit capture workflow

- Updated: 2026-10-28 (America/New_York)
- Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`
- Branch: `main`; identify the current checkpoint with `git log -1 --oneline`.

## Objective

A reusable Swift package and standalone macOS example, following CMResearchKit's
ownership model, prepare geographic textured assets for user import into
MessScene. GLB versus USDZ consumer delivery remains deferred.

## Definition of Done

A user selects a geographic area/detail, captures and previews it, saves it,
and imports its final delivery into MessScene with correct appearance, scale,
and placement. Neither app is a dependency of the package.

## Current Bounded Milestone

Checkpoint: the user authorized committing and pushing all current MessEarthKit
work. Scope includes the root package, example Xcode app, fixture/test/probe tools,
and current documentation. The remote was fetched and matches the planning
checkpoint. Apply the parent SwiftFormat configuration to staged Swift files,
review the staged snapshot, and verify the package/example before committing on
the existing main branch and pushing origin/main. Keep the saved live capture,
credentials, build output, other repositories, and super-repository pointers out
of this checkpoint. Done: the commit is pushed and owning-repository status is
clean. This authorization supersedes the earlier planning-only commit scope.

Commit preparation: all 54 changed/new files are explicitly staged. The staged
Swift list has 29 files; SwiftFormat changed 20 using only the workspace's existing
configuration. Review confirms mechanical whitespace, wrapping, import ordering,
numeric grouping, and redundant-parenthesis changes. No active local hooks or
additional remote commits were found. Final validation passed: all 16 offline
package tests, the affected macOS example build, scoped lint for all 29 staged
Swift files, and staged diff checks. This implementation checkpoint records the
validated snapshot; use Git history and branch tracking to identify the commit
and remote state. No live API calls or cloud changes were made for this checkpoint.

Completed: make the per-capture source-request budget user-settable. Owner:
MessEarthKit's immutable EarthCaptureRequest and traversal, plus the example's
capture controls/view model. Add a positive whole-number Maximum Requests field
with the existing 512 default, pass it into each capture, and show used/allowed
requests in progress. Keep byte, geometry, node, and placement limits independent.
Done: controlled downloads stop exactly at a custom budget, a raised budget
allows more than 512 requests, recovery retains partial metadata, and focused
package tests plus the affected macOS example build pass. Inspect public API
consumers: only the example, probe, and tests currently use these request/progress
types; a workspace search found no additional consumers. No live API calls,
cloud quota changes, GUI launch, or commits are needed.

Implementation stage: the request carries `maximumSourceRequests` (positive,
default 512), traversal enforces that immutable budget, progress exposes actual
source request counts, and incomplete metadata retains the chosen budget.
The example has a Maximum Requests field and used/allowed progress; the probe
shows the same count. Existing recovery coverage now includes custom exhaustion
at 3 and completion at 513, alongside default exhaustion at 512; one small
parameterized validation test rejects zero/negative budgets. All 16 package tests
and the affected macOS example build passed. Review also moved the request
counter increment after the byte-budget check, so a request blocked before
transport does not consume the displayed request budget. The final focused
session tests (three tests with six recovery and two validation cases) and the
example build pass too. Code/document review, whitespace checks for all eight
changed source/README files, and `git diff --check` pass. Milestone complete.

Completed: recover downloads after `Source request count` stops capture.
The old attempt cannot be recovered: traversal data was local memory, unwound
on error, and the ephemeral transport has no disk cache. Only the earlier
successful Cincinnati capture exists on disk. Implement a per-attempt recovery
folder supplied by the app, checkpoint each completed GLB before publishing its
atomic local manifest, and mark interrupted snapshots explicitly partial.
Keep the 512-request and geometry budgets. The app should preview usable partial
results and expose retained downloads after cancellation, decode failure, and
restart. Owner types: EarthCaptureSession, new manifest/checkpoint helpers,
EarthCaptureImporter/EarthCapture.incompleteReason, and an app-owned recovery
service/view. Done: controlled request-cap/cancellation/decode failures retain
reopenable credential-free sources, complete snapshots clear the partial marker,
and focused tests plus the macOS example build pass. No API calls are necessary.

Library checkpoint stage passes **15 tests**, including four controlled lifecycle
cases: complete, 512-request exhaustion, cancellation after a committed tile,
and decode-budget failure. They verify durable source bytes, placement, safe
metadata, completion-marker clearing, partial save/reopen, and existing-folder
protection. The app now owns recovery folders under Application Support,
previews decodable interrupted results, and discovers downloads after restart.
The CLI now checkpoints directly into its supplied new destination. The macOS
example build passes. The updated CLI reopens the earlier successful Cincinnati
capture offline with the same 152 meshes, 184737 triangles, 554211 vertices,
8202022 source bytes, and bounds; `isPartial` is false. No live Google request
has been made during this task. The bounded recovery milestone is complete;
the old failed attempt remains unrecoverable.

Completed: the user asked to add an estimated capture cost.
`EarthCaptureCostView` appears beside Capture Region and shows the global USD
standard-rate estimate of **$0.006 per capture**, the shared monthly free allowance
with unknown remaining balance, a verified date, and an official pricing link.
Help text explains that sessions can count even if a capture fails or is cancelled.
The library and network behavior are unchanged. The example build and all 13
existing package tests pass. No tests were added for static presentation copy.
An offscreen render of the actual view verified the three-decimal amount and text
layout without launching the app. The native Link is not supported by that
offscreen renderer; its normal SwiftUI implementation builds and targets the
verified public pricing page. No paid API calls or cloud changes were needed.
Verified 2026-10-28: Google lists $6/1000 Photorealistic 3D Tiles root sessions
after 1000 free monthly events; the current capture path starts one root session.
Sources: Google's global pricing table and official GA billing announcement.

Completed: repair the false `detailUnavailable` error and verify the real
Cincinnati capture at the original **200 x 200 m / 4 m** settings. Capture, native
decoding, source-folder save, and offline reopen now succeed. The result is
**152 meshes, 184737 triangles, 554211 prepared vertices, 112 original GLBs plus
one local manifest, and 8202022 source bytes**. Reopened triangle count and bounds
match the captured values. All **13 package tests**, the macOS example build,
and app signature verification pass. No GUI was launched.

Root cause: East/South-only projection selected tiles on the far side of Earth.
A metadata trace found the rejected leaf near latitude -39.274, longitude 95.537,
about 12735 km below Cincinnati's tangent plane, with geometric error 1027 m.
`EarthRegionSelection` now rejects bounds wholly behind the Earth-center plane
while retaining crossing/global roots. The existing capture/save test adds
opposite-side box and sphere leaves and a globe-enclosing parent; it reproduced
the failure before the repair.

The real tiles omit optional sampler filters. `EarthGLBDecoder` validates explicit
filter values in source JSON, then maps GLTFKit2's zero sentinel for omitted
minFilter to the existing linear/mipmap default. One focused original-fixture
variant test covers omission versus explicit invalid zero without another binary.
All 112 saved real GLBs omit minFilter and use `KHR_materials_unlit`.

Saved capture:
`/Users/jvcleave/Library/Application Support/MessEarthKit/Captures/cincinnati-race-st-2026-10-28/tileset.json`.
The manifest references only the 112 local GLBs and contains no service URL,
key, or session. Whole tiles extend the actual bounds to approximately
(-110.933, 98.835, -127.395) through (127.610, 231.415, 102.048) meters.
The numeric report is `<central>/verification/cincinnati-capture-result.json`;
a sanitized rejected-leaf trace and small real sample are retained beside it.

The user-authorized daily root-request cap remains **100**. The previous 10/day
cap caused confirmed HTTP 429s; a transient 429 also occurred during this repair,
followed by successful native access and the final successful capture. Google
1.0 tilesets requiring `3DTILES_content_gltf` remain supported. Credentials,
resource budgets, default detail, and final delivery format were not changed here.

## Non-Goals

Source-policy review (handled separately by the user), super-repository or
submodule changes, MessScene integration, final GLB/USDZ delivery selection,
map-selection UI, release work, and changes outside MessEarthKit. The user has
now explicitly authorized the current implementation commit/push checkpoint.

## Repository State

The starter Xcode app was untracked at implementation startup; its project
identity and signing team are preserved. The authorized implementation checkpoint
includes the root package, private codec bridge, fixtures/tests/probe, and app.
Existing planning and alternative-source notes are preserved. Build output stays
outside the repo.

XcodeOpenWorkspace was previously denied. Do not open/launch through another
route without a new explicit request. The user later had the project open;
network/read-write settings were applied with Xcode's build-setting tools to
that already-open project. No GUI was launched during verification.

## Decisions and Constraints to Preserve

- One public `MessEarthKit` library module; private `EarthDracoBridge` target.
- GLTFKit2 0.5.15 and DracoSwift 1.5.7 pinned in both package and Xcode locks.
- The package owns source requests, selection, decoding, immutable CPU assets,
  transforms, and source serialization. The app owns credentials, address lookup,
  job lifetime, destination authorization, presentation, and preview resources.
- The Google key is entered in a secure field, held only in memory, and absent
  from saved local manifests. This setup now adds a dedicated app-owned Keychain
  item for the newly authorized development key. Network errors omit source URLs;
  never print key strings or put them in source, command arguments, or artifacts.
- Source GLBs are byte-preserved. A rewritten ordinary 3D Tiles manifest retains
  selected transforms/bounds without API URLs/session parameters. Source folders
  reopen without network; this does not decide final consumer delivery format.
- Local meters use East +X / Up +Y / North -Z. Subtract geographic origin in
  double precision before creating float vertices.
- The example defaults to the supplied address; MapKit returned one result at
  latitude 39.1026327, longitude -84.515172. Changing the address clears old
  coordinates, and manually edited coordinates do not retain the old place name.
- Default area is 200 x 200 m and maximum geometric error is 4 m. Whole tiles
  may extend beyond the region. Selection uses explicit ADD/REPLACE refinement.
- Downloads are serial and bounded: configurable positive request budget (default
  512), 256 placements, depth 64,
  16 MiB per response, plus configured source/node/geometry/texture limits.
- Native Draco decoding has a fixed 2M-point/2M-face ceiling; the Swift adapter
  additionally enforces caller limits. GLTFKit2's stateless plugin is installed
  once; each decode owns its native runtime and outputs.
- Save creates a new folder, never replaces one, and removes its own partial
  save output on failure/cancellation. Recovery checkpoints instead retain
  completed tiles after failure/cancellation, with no automatic pruning or resume.
  Host-owned security scope stays active.
- Original local fixtures and the retained USGS/FEMA/NAIP alternative remain.
- No runtime Python/Blender/toolchain dependency or sibling checkout paths.

## Relevant Files

- `README.md` and `AGENTS.md` — setup, supported subset, limits, ownership rules.
- `MessEarthKit/MessEarthKit/Presentation/EarthCaptureCostView.swift` — app-owned
  published-rate estimate and account-allowance explanation; no billing access.
- `Package.swift` and `Package.resolved` — exact remote/native dependencies.
- `Sources/MessEarthKit/API/EarthCaptureSession.swift` — bounded capture traversal.
- `Sources/MessEarthKit/Tiles/EarthCaptureManifest.swift` and
  `EarthCaptureRecoveryWriter.swift` — sanitized completion metadata and durable
  payload-first, atomic-manifest checkpoints.
- `MessEarthKit/MessEarthKit/Services/EarthCaptureRecoveryService.swift` — app-owned
  recovery folders, partial fallback, and restart discovery.
- `MessEarthKit/MessEarthKit/Presentation/EarthCaptureRecoveryView.swift` — explicit
  incomplete warning and Open Last Download / Show Downloads actions.
- `Sources/MessEarthKit/Tiles/EarthGoogleTileClient.swift` — ephemeral transport,
  byte limits, no redirects, sanitized errors.
- `Sources/MessEarthKit/Geometry/EarthRegionSelection.swift` — box/sphere/region
  intersection, pole/date-line handling, transformed error bound.
- `Sources/MessEarthKit/API/EarthCaptureImporter.swift` and `EarthCaptureStore.swift`
  — shared CPU decoding, original source values, and ordinary-folder save/reopen.
- `Sources/EarthDracoBridge/` — private stateless Objective-C++ codec bridge.
- `Tests/MessEarthKitTests/EarthCaptureSessionTests.swift` and `EarthDracoTests.swift`
  — controlled source and independent compressed-reference verification.
- `Tests/MessEarthKitTests/Fixtures/DracoBox/PROVENANCE.md` — upstream hashes and
  Khronos/Cesium CC-BY-4.0 fixture attribution.
- `MessEarthKit/MessEarthKit/Presentation/EarthWorkspaceViewModel.swift` — user
  actions, cancellation, secure key, preview preparation, and destination access.
- `MessEarthKit/MessEarthKit/Services/EarthLocationLookup.swift` — MapKit address
  lookup returning plain values to the UI owner.
- `MessEarthKit/MessEarthKit/Services/EarthAPIKeyStore.swift` — reads the dedicated
  app-owned login-Keychain item; manually entered keys remain in memory only.
- `MessEarthKit/MessEarthKit.xcodeproj/xcshareddata/xcschemes/MessEarthKitExample.xcscheme`
  — explicit runnable app scheme; avoid the automatic package-name scheme.
- `docs/internal/plans/MESS_EARTH_KIT_INITIAL_PLAN.md` — staged scope and acceptance.

## Verification

- Authorized implementation checkpoint: after commit-time formatting, all 16
  package tests and the MessEarthKitExample macOS build passed again. SwiftFormat
  lint reports 0/29 files needing changes; staged diff checks pass. The retained
  tests cover source/placement/material fidelity, native Draco compatibility,
  bounded input/traversal, transport/session handling, save/reopen, recovery and
  completion metadata, cancellation, and configurable request boundaries. No
  redundant tests or extra fixtures were added for commit preparation.
- Settable request budget: all 16 package tests and the macOS example build
  passed; after the final counting adjustment, three affected session tests and
  the example build passed again. Existing recovery coverage now proves custom
  exhaustion at exactly three requests and successful completion at 513 while
  retaining the prior 512-boundary/cancellation/decode cases. One validation test
  rejects zero/negative budgets. No fixture files or UI tests were added.
- Download recovery: **15 package tests passed**, including parameterized
  complete, 512-request exhaustion, cancellation after a committed tile, and
  decode-limit failure. Distinct risks covered are durable source/placement
  preservation, partial-marker persistence/clearing, credential-free metadata,
  rejection of malformed metadata, and existing-directory protection. The
  affected macOS example build passed. Updated CLI offline reimport of the real
  Cincinnati capture reports unchanged geometry and a complete capture. No GUI
  launch, API calls, cloud changes, or implementation commits were needed.
  App signature verification and `git diff --check` passed; an explicit whitespace
  check covered all 29 new Swift/README files, including the recovery additions.
- Capture-cost UI: affected example build and all 13 package tests passed.
  Headless SwiftUI render at the 1000 px minimum window width verified $0.006
  and unclipped cost text. Native Link rendering/interaction remains for actual
  GUI inspection. Helper and PNG are under `<central>/verification/`.
- Authorized quota increase: Service Usage operation completed without errors;
  a separate metric read confirmed effective daily root quota 100. Evidence is
  in `<central>/verification/root-quota-increase-operation.json` and
  `verified-root-quota-100.json`. `cloud-setup.json` and the applied proposal now
  record 100. No other cloud setting changed and no new root request was issued.
- HTTP 429 follow-up: current Service Usage metadata confirms effective daily
  root quota was 10 before the increase; Cloud Monitoring confirms the exceeded limit is
  `ThreeDTilesRootTileSetPerDayPerProject` and records root-method 429 responses.
  Non-secret evidence is in `<central>/verification/current-root-quota.json` and
  `current-quota-errors.json`. Twelve package tests and the affected macOS example
  build passed after clarifying the 429 description. No extra root requests or
  cloud mutations were needed.
- Cloud setup: verified exactly one dedicated development key restricted to
  `tile.googleapis.com` and the current public IPv4/IPv6 addresses. The key was
  retrieved only in memory, passed to a temporary helper over stdin, and stored
  under service `com.jvclabs.MessEarthKit.MapTiles`, account `default`, in login
  Keychain with the signed example app on its trusted-app list. No key string
  was printed or written to source/config files.
- Authenticated Google root request: HTTP 200, tileset version 1.0, required
  `3DTILES_content_gltf`. No root session URLs or response content were retained.
- Real capture verification at 39.1026327, -84.515172, 200 x 200 m, 4 m error:
  completed traversal and native decoding, saved 112 GLBs plus a local manifest,
  and reopened with identical triangle count and bounds. The CLI report records
  152 meshes, 184737 triangles, 554211 vertices, and 8202022 source bytes. A disk
  audit confirmed all 113 files, byte totals, and local-only manifest references.
- `Tools/IntegrationProbe/main.swift --capture` reads the key only from stdin
  and uses public capture/import APIs for the live check, retaining its supplied
  new destination as a recovery folder even when capture throws.
- Google quota: daily root-request default was 10000. Set only this new service's
  root daily consumer override to 10, explicitly acknowledging the >10% decrease
  check while retaining other quota safety checks. Operation completed and
  effectiveLimit=10 was confirmed through the API.
- App credential-loader change: affected macOS build and
  `codesign --verify --deep --strict` passed. Runtime app GUI/Keychain loading
  remains for user launch; restart to load the newly created credential.
- Non-secret setup/operation metadata and the temporary Keychain helper are
  under `<central>/verification/`; metadata does not contain the key or tokens.
- Central root:
  `/Users/jvcleave/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds/MessEarthKit`.
- `swift test --scratch-path <central>/swiftpm`: **13 tests passed** after the
  hemisphere-selection and omitted-filter repairs. The existing capture/save test now covers Google's
  required extension on root, external JSON, and original local 1.0 imports; one
  test proves unknown required extensions remain explicit failures. The capture
  test also covers far-side box/sphere rejection without pruning a global parent;
  one new sampler test covers valid omission versus invalid explicit zero.
  Retained tests cover distinct
  placement/material/source fidelity, malformed input/budgets, directory and
  host authorization, request/session propagation, save/reopen, cancellation,
  geographic boundary cases, and native Draco compatibility.
- `xcodebuild -quiet -project MessEarthKit/MessEarthKit.xcodeproj -scheme
  MessEarthKitExample -destination 'platform=macOS,arch=arm64' build`: passed.
- Built app/framework signatures, Metal library/reference resources, network
  client + user-selected read/write entitlements, macOS 15.6 target, and both
  exact dependency locks were verified.
- A standalone MapKit lookup of the supplied address returned one exact match;
  no Google key or authenticated Google request was used.
- Prior local probe: 4 meshes, 56 vertices, 28 triangles, 5113 native source
  bytes, correct bounds (-4, 0.5, -7) to (10, 2.3, -1).
- Prior actual-shader headless Metal check verified cardinal texture orientation
  and opaque/discarded MASK fragments. Preview rendering did not change here.
- Final code/diff and `git diff --check` passed. Explicit whitespace checks
  covered 43 new text files; local links and independent fixture/license/hash
  were verified. No local `.build` or unrelated repository changes were added.

## Remaining Issues

The real capture/save/reopen path is verified. GUI interactions and actual
preview texture appearance still need user inspection. The final GLB/USDZ
consumer format and MessScene import remain deferred. Meshopt, sparse accessors,
animation/skinning, extra material maps, implicit/legacy tile containers, and
external GLB resource URLs remain unsupported. Lit preview uses directional
shading rather than full PBR. Transient Google HTTP 429s may still occur.

## Next Exact Action

The capture repair, cost display, durable recovery, and settable request-budget
milestones are complete. The user should rebuild/run **MessEarthKitExample** and
set **Maximum Requests** beside Detail error; default 512, positive whole number.
Progress now shows requests used/allowed. Future interrupted captures
retain completed tiles and offer **Open Last Download** / **Show Downloads**;
the app previews decodable partial results with a visible warning. The older
failed attempt was never saved and cannot be recovered. **Open Tileset Folder…**
can still open the earlier saved Cincinnati capture without a new API request.
The existing default 200 x 200 m and 4 m settings support the verified live capture.

Next independent milestone: validate the actual GUI preview/interaction and
source appearance, then resume the deferred consumer-delivery decision when
requested. Do not launch the GUI without a new explicit request, change the
100/day quota, or begin MessScene integration on this checkpoint's authority.
The current commit/push checkpoint is explicitly authorized; later commits need
their own task authorization.

**Fresh-task startup:** Read this handoff, inspect owning-repository `git status`
and scoped diffs, then follow **Next Exact Action** and the listed sources.
Consult conversation history only for a missing authorization or constraint.
