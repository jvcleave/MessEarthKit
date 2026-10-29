# Disk-backed acquisition, local model preparation, and request history

Status: request visibility and durable acquisition implemented and verified.
Stage 3A file-backed preparation is implemented and verified.
Stage 3B1 geometry subdivision and native topology admission are verified.
Stage 3B2A exact base-level texture subdivision and 3B2B explicit portable
optimized copies are implemented and verified. Exact mip/normal reproduction
across crop boundaries and broader native isolation remain separate future work.
SDK Separate models / Combined GLB export with offline preflight is complete.
The example's former split workspace is being replaced. Changes are uncommitted.
Next approved front: the
[project workflow reorganization](PROJECT_WORKFLOW_REORGANIZATION_PLAN.md).
Projects → Project Details (capture editor + MapKit) → 3D Preview → Export, plus Settings,
supersedes the split-workspace presentation. The app-files foundation, persistent
project library/draft details and global Settings are implemented and verified.
The old app inspection/recovery/calibration route was removed. App formats have
no legacy readers, migrations or silent fallbacks. MapKit confirmation, explicit
Download/resume and automatic offline preparation are implemented. Whole-region
Metal composition and the new Export screen remain pending.
Updated: 2026-10-29 (America/New_York).
Owner: MessEarthKit package and MessEarthKitExample macOS app.

## Outcome

The user enters an address, dimensions, and resolution, then downloads the area.
Raw sources stream into a durable local capture without product-imposed total
byte, tile, request, vertex, or texture ceilings. A separate offline stage creates
models for the selected destination's requirements. Model preparation can be
rerun or changed without downloading the same capture again.

The adopted user model is a named project with saved capture variants, one selected
region preview and one exported file or folder per operation. Internal preparation and
model partitioning are automatic. Source selection needs location/area/detail;
output format and destination packing budgets are chosen offline later. Project
navigation and settings are specified by the linked reorganization plan.

The example also displays a persistent, clearable local counter of API request
attempts during the last 30 days. No Google request is needed to show that counter.

This plan updates the acquisition direction of the
[initial plan](MESS_EARTH_KIT_INITIAL_PLAN.md). The existing sectioning work is a
starting point, not the final acquisition architecture. Focus implementation on
the example and reusable SDK first; defer further MessScene changes until this
workflow is proven. Google source-policy review remains separately owned as
previously directed by the user.

## Current source and gaps

- `EarthSourceAcquisition` streams payloads to files, journals work in SQLite,
  validates hashes on resume, and publishes a raw artifact without mesh decoding.
  Metadata refresh compares sanitized hierarchy and advertised source versions.
  Same-URI server changes without metadata/version signals cannot be inferred.
- App milestones 1–4 supply persistent project IDs, draft forms, Settings and
  MapKit beside the capture editor before Download. Dimensions/detail redraw the
  footprint in place; Update Map resolves address changes without another route. The paused source journal/reference is
  created offline before transport, so interrupted transfers reopen by identity.
  Download/resume automatically leads to offline preparation; stale completion
  cannot change navigation after Back. Old manual panels are no longer primary UI.
- Reopening uses the current project's explicit source/preparation references,
  verifies request/profile/source hashes and never chooses an unrelated newest
  archive. Draft changes leave the downloaded request and source files unchanged.
- `EarthAppFiles` now supplies Documents/project/source/prepared/output locations,
  atomic bounded metadata I/O and access leases. App root selection/file primitives
  are centralized; SDK streaming/SQLite stays unchanged. Project identity is now
  durable, and Settings/usage are app-owned. There is no old-root or
  newest-archive startup scan.
- The new acquisition path removes whole-job byte/request/tile/node ceilings and
  accepts dimensions above 5 km with explicit wrapped/polar surface selection.
  Metadata retains a 16 MiB/depth-bounded parser and structural safeguards.
- Legacy `EarthCaptureSession` capture/inspection and immutable-byte collection APIs
  retain their Data-based source storage and bounded import contracts. Their
  limits no longer gate normal raw downloads or the new file-backed planner.
- Legacy section planning splits whole source tiles by geometry/texture estimates, with
  64 sections and 64 placements per section as additional fixed checks. It does
  not subdivide a source mesh or texture that is too large on its own.
- `EarthModelPreparer` now inspects one payload at a time, sorts placement rows
  in SQLite and writes independent model folders incrementally. Its versioned
  per-model profile, paged catalog and file-based subset saver have no total
  model-count ceiling. The current project UI composes the entire prepared region
  after automatic preparation with aggregate GPU admission and full shared bounds.
  Legacy byte collections above keep their existing SDK limits.
- Geometry exceeding destination budgets now splits into derived triangle models
  within a separate 128 MiB/2M prepared-vertex/6M index source working set. Textures
  with unsupported crop semantics and sources beyond that working set remain explicit.
- Base-level nearest/bilinear textures now crop without reducing resolution,
  clip triangles in baked UV space, and preserve wrap/filter edges with gutters.
  The raster working set is 16K/256 MiB RGBA with bounded repeat/clip work/cache.
  Preserve appearance rejects mipmapped crops and changed lit-normal
  interpolation. Optimized copy explicitly permits regenerated crop mipmaps and
  normalized clipped normals without changing base image resolution. Unsupported
  pixel representations remain explicit; original files are always retained.
- Preparation profile v2 records the appearance permission; v1 decodes as exact.
  Prepared/derivative manifests, source-folder copies and combined GLB retain it,
  and reopened previews show recorded optimization permission. The new Export
  screen will provide the explicit choice before preparing an optimized output.
- Draco topology admission now runs before native decode and ignores glTF count
  claims. The conservative Edgebreaker bound is three points per face. Post-decode
  checks remain, and prefix admission is not complete native-memory isolation.
- Source-folder collections preserve a shared origin and original GLB bytes.
  SDK subset export remains supported; the planned project Export screen uses
  the entire capture. The rolling local usage counter is global under Settings.
- `EarthCaptureProgress.sourceRequests` is per job and repeatedly published. It
  is not a persistent request ledger and must not be summed to produce one.

## Ownership and artifacts

The SDK owns transport, selection, source integrity, immutable job events and
results, and consumer-neutral preparation contracts. Workers perform file and
codec work. The example owns destination authorization, storage locations,
scheduling, retained captures, local usage persistence, and presentation.
Views send typed intents and consume cached typed display items.

Use two separate artifacts:

1. **Raw capture:** immutable original GLBs, sanitized source hierarchy and
   transforms, requested area/resolution, geographic origin, integrity metadata,
   and durable acquisition progress/completeness. Preparing models must not edit it.
2. **Prepared collection:** destination profile/version, shared origin, model
   manifests and derived geometry/textures, plus references back to the raw capture.
   A failed or canceled preparation leaves the raw capture available.

The host supplies a job directory and retains authorization for its lifetime.
New file-backed source handles replace whole-capture `[EarthSourceFile]` arrays
on the large-download path. Existing small immutable-byte import APIs can remain
for clients that explicitly choose them. Do not require a complete `EarthCapture`
or decoded scene to declare an acquisition successful.

## Acquisition contract

- Stream GLB payloads to temporary files using bounded buffers and concurrency;
  atomically publish completed payloads into the capture. Do not decode meshes
  or images to decide whether the requested area may finish downloading.
- Keep a durable pending/completed tile index and hierarchy/placement records.
  Page traversal state from disk as needed; a huge selected region must not
  require a huge in-memory queue or one giant checkpoint JSON rewrite per tile.
- Remove arbitrary whole-job byte, request, tile, visited-node, and section caps
  from the normal acquisition path. A legacy API budget must not silently become
  a mandatory example-app ceiling. Keep scheduling controls internal.
- Replace the arbitrary 5 km area restriction with explicit valid geographic
  extent handling. Traverse or subdivide large selection footprints internally,
  including date-line/polar cases; do not silently change the entered dimensions.
- Resolution expresses the requested source detail. Record the requested target
  and report unavailable source detail explicitly; do not silently lower quality.
- Retain format checks, cycle detection, endpoint confinement, bounded parser
  working sets and structural validation. Rework a per-response GLB size ceiling
  into streaming rather than requiring larger `Data` allocations. Metadata needs
  its own validated incremental/bounded-reader strategy.
- Available disk space, valid source data, service availability/quotas, and user
  cancellation remain real constraints. Disk exhaustion or network failure must
  preserve completed payloads and identify what remains incomplete.
- Pause/cancel must not erase committed sources. Resume may reacquire service
  metadata/session access, then reuse validated completed files. Refresh expired
  service URIs without persisting keys or session tokens in the capture. Detect
  changed source versions rather than silently mix incompatible coverage.
- Do not claim byte-range resume unless the transport/source supports and
  verifies it. Retrying one interrupted file is acceptable; restarting completed
  files is not the default. Keep capture archives immutable once complete.

## Offline preparation contract

- Read only the required source files or ranges for each unit of work. Keep
  native objects and decoded geometry inside an owning worker, releasing them as
  prepared models are written. Avoid a fully decoded collection in memory.
- Use an explicit destination profile: geometry/index limits per mesh/model,
  supported texture dimensions/formats, texture/geometry working budgets,
  material capabilities and coordinate conventions. The profile is data owned
  by the consuming boundary; the SDK must not import MessScene or MESS types.
- Pack nearby content into models automatically. An internal packing target may
  bound each model, but reaching it starts another model instead of ending the
  capture. Remove the fixed total-section ceiling; index and page large catalogs.
- When a single source tile exceeds output requirements, partition its triangles
  into valid meshes and divide/repack textures with correct UVs as required.
  Preserve scale, shared placement, winding, normals, materials and attribution.
  Resolution-reducing derivatives require an explicit quality choice; originals
  remain intact. Whole-tile grouping alone is not the completion criterion.
- Prototype the oversized-single-primitive decoder strategy before promising
  arbitrary preparation sizes. Isolated native work, decoder admission/resource
  controls, and bounded preparation errors remain necessary. Failure here must
  not relabel an already downloaded source capture as an acquisition failure.
- A different profile or a selected subset can be prepared offline. The prepared
  result records whether it covers all acquired content or the chosen subset.
- The reorganized example targets one whole-region preview composed from its
  internal parts within an admitted aggregate GPU working set. Two bounded import
  passes check geometry/textures/mips/headroom before whole-scene upload. Oversized preview failure
  retains downloaded data and supported exports; streaming/overview is follow-up
  work. Output splitting does not itself make all models fit GPU memory.
  General renderer streaming in MessScene is outside this plan.

## Export choices: separate models or combined asset

User-approved addition: before export, let the user choose **Separate models**
(the existing aligned collection) or **Combined asset** for the selected models.
Implemented first container: **Combined GLB**, reimported through the SDK/example.
USDZ remains optional future work.

These selected-model APIs remain supported. The first project-based UI exports
the entire current capture as one GLB or one folder, hides individual selection,
and places output choices on a navigation destination rather than an overlay.
See the project workflow plan for automatic preparation and job ownership.

- Combined asset produces one independently importable asset with a shared root
  and original placement. Retain internal meshes, material assignments, textures,
  attribution and source/profile provenance; no welding or material flattening is
  required. Selection spans the paged catalog and may be a subset.
- Validate the combined result against the destination's geometry/index, texture,
  file-format and resource requirements before writing it. Explain any excess
  and keep Separate models available. Do not silently lower quality, drop models
  or assume packaging as one file removes the consumer's limits.
- Perform the operation offline from prepared model files with bounded working
  memory and cancellation. Leave raw archives and prepared collections unchanged;
  write a new output and never replace an existing destination.
- Record full-source versus selected-subset coverage. A failed or canceled export
  must leave the inputs available for another selection or export mode.
- GLB stores ordinary uncompressed geometry and original encoded images. Keep
  internal derivative generation separate from standalone delivery. The file's
  32-bit length, 16 MiB JSON parser bound and destination profile apply to the
  combined selection; reaching one leaves Separate models available.

EarthGLBExporter checks catalog estimates before decoding, then builds bounded
metadata one prepared model at a time. Its immutable plan includes exact output
bytes and selected-file fingerprints. Export checks those fingerprints again,
streams bounded binary buffers and atomically publishes a new file. A dedicated
MVVM owner invalidates cached checks when selection/budgets change. Origin,
profiles, selected IDs, coverage and individual notices survive GLB reopening.

Acceptance: combined subset import preserves independent shared-origin placement,
geometry, normals, UVs, materials/textures and attribution; invalid combined
budgets are reported before output, cancellation retains inputs, and export adds
zero network requests. Verify the actual chosen container with its consumer.

## Local request counter

### User-visible behavior

- Show **Requests — last 30 days**, with a compact **Session requests** count and
  a **Clear counter** action. Detailed root/metadata/GLB and outcome counts can
  live in an expandable usage view.
- The window is the trailing 30 × 24 hours, computed from recorded UTC instants,
  and refreshes as events age out. It is not a calendar billing month.
- Count requests made through this local example installation, across capture,
  API inspection, resume and explicit retries, including any API keys used here.
  Requests from Google Console, another app/device or another project client are
  outside this local history. It cannot report the billing account's remaining
  free allowance, quota balance, or actual bill.
- Record the tracking start time and last clear time. On first run, show that
  tracking starts now; do not infer historic requests from saved source manifests
  or imply an empty new ledger proves zero account usage during the prior month.
- Clearing removes/resets local request statistics and begins a new tracking
  epoch. It does not delete captures, keys, preparation outputs, job checkpoints,
  or their provenance, and it does not reset anything on Google's side.

### Counting semantics

- Emit one unique request-attempt event when a real network operation enters
  the transport, after input validation, cancellation checks and local cache
  lookup. Do not count queued work that never reaches transport.
- Classify root-tileset/session attempts separately from child metadata requests
  and GLB requests. Call these **session requests**, not confirmed billable
  sessions: a failed request or later job failure does not prove a billing result.
- Count each explicit retry as another attempt. HTTP errors, authentication
  rejection, network errors and cancellation after transport entry remain
  attempted requests. Track outcomes separately so failures are understandable.
- Cache hits, local reopen, offline estimates, model splitting, preview and save
  add zero requests. Source progress events do not increment this ledger.
- Request start creates the count; completion updates the same event rather
  than creating another. SDK capture and inspection must share this instrumented
  transport, including future retry/session-refresh paths.
- Clear during an in-flight request starts a new ledger epoch. A completion
  from the old epoch cannot recreate a cleared entry. Later attempts are counted
  in the new epoch, including later attempts in the same capture job.

### Persistence and privacy

- Add actor-owned local usage storage under the example's Application Support
  directory, separate from source captures and estimate history. Use indexed
  timestamps and prune entries older than 30 days. Do not add a record-count cap
  that silently undercounts a busy month.
- Persist attempt IDs, timestamps, request kind, optional opaque job ID,
  outcome/status and byte counts only. Do not store keys, full URLs, session
  tokens, addresses, capture coordinates or response bodies in request history.
- Survive restart and clear atomically. Interrupted attempts remain identifiable
  as unknown/incomplete outcomes. Treat this as local attempted-request telemetry,
  not an exact server-side delivery or billing audit across process crashes.
- If usage storage fails, surface that tracking is incomplete and retain
  downloads. Do not silently reset the display to a trustworthy-looking zero or
  make remote capture depend on the statistics store being writable.

## Staged implementation

1. **Request visibility.** Add actor-neutral typed transport events, the app-owned
   rolling ledger, cached usage display and Clear counter. Verify all existing
   network entry paths are counted once. This can ship before the disk refactor.
2. **Durable file-backed acquisition.** Introduce a source-job artifact and
   streaming transport. Replace in-memory resource retention, whole-job ceilings
   and repeated full-manifest checkpoints. Keep raw downloads independent from
   codecs. Prove interrupted/restarted jobs reuse completed payloads.
3. **Offline preparation.** Stage 3A implements file-backed profile planning,
   incremental model folders, uncapped total model count, paged catalog reads,
   single-model import and selected export. Stage 3B1 adds geometry partitioning
   for admitted source working sets and native topology checks before decode.
   Stage 3B2A adds exact admitted base-level crops/UV clipping; 3B2B adds opt-in
   portable copies with regenerated crop mipmaps and approximate clipped normals.
   Exact cross-region mip/normal support and broader native isolation remain
   future work beyond the current portable contract. See
   [the native boundary assessment](NATIVE_PREPARATION_BOUNDARY.md); whole-tile
   packing is not completion of that subdivision stage.
4. **Project workflow reorganization (next).** Follow the milestones in
   [the adopted UI plan](PROJECT_WORKFLOW_REORGANIZATION_PLAN.md): centralized
   app-files ownership and current-format project library/navigation/Settings are
   complete. MapKit-confirmed Download/resume and automatic preparation are also
   complete. Whole-region preview, its local checks and the affected app build
   are complete. Next is whole-capture Export.
   Show distinct download/preparation/preview outcomes without manual model
   management. Back navigation does not cancel project-owned jobs.
5. **Export modes (SDK implemented; new UI planned).** Retain Separate models /
   Combined GLB APIs and structure/limit validation. The project Export screen
   chooses one folder or GLB for the whole current capture. Appearance is explicit;
   technical output budgets stay advanced/internal. USDZ remains future work.
6. **Acceptance gate.** Local acquired-source preparation/retry and folder/GLB
   delivery checks pass. The reorganized project/navigation/whole-region workflow
   now has local fixture checks; the Export screen and full GUI acceptance remain.
   Revisit MessScene after that boundary is proven.

## Focused verification and acceptance

- Existing orientation, Draco, source confinement, cancellation and section
  placement contracts remain valid; inspect affected public API consumers.
- Generated local streams cross the old 128 MiB total and 16 MiB payload limits
  without full-response `Data` buffering. Generated traversal crosses old
  total-node/tile/section ceilings without lost placements. Avoid large committed
  fixtures or bespoke verification executables.
- A decoder failure or profile mismatch occurs after a successful raw download;
  sources remain available and offline preparation can be retried with a new
  profile, with no transport events.
- Recovery tests cover interruption before/after atomic file commit, restart,
  expired access, changed source identity, disk failure and selected-subset output.
- Usage tests use an injected clock and transport to cover the exact rolling
  cutoff, failed/retried attempts, cache hits, restart, first-run coverage, clear
  during an in-flight request, stale completion and persistence failure.
- Representative mesh/texture splitting preserves independent placement and
  material/UV contracts. An oversized native primitive has a documented tested
  outcome; do not claim unbounded decoding from acquisition success.
- Build the affected macOS example and run focused SDK checks appropriate to
  each stage. Use the centralized SwiftPM scratch path in AGENTS.md. No live
  service calls, cloud changes, GUI launch, commits or pushes are authorized by
  this planning request.

## First bounded milestone

**Request visibility is implemented:** total local attempts and root/session
attempts over a rolling 30 days, persisted across restart with Clear counter.
The SDK has actor-neutral transport events and an indexed SQLite usage store
at a host-supplied location. The example owns its observer wiring and a focused
presentation owner with cached text, throttled updates and expiration refresh.
No URLs, keys, tokens, addresses or response payloads enter history.

Passed: four focused usage tests (one with three transport cases), the five
existing precheck cases after transport changes, and the affected macOS example
build. Tests cover exact cutoff, duplicate delivery, cache/offline operations,
retries, HTTP failure, cancellation, restart, clear while in flight, missing
outcomes, storage recovery and credential exclusion. Source/diff review passed.
No live calls, GUI launch, commits or pushes were performed.

Subsequent milestones implemented durable acquisition, file-backed preparation,
geometry/base-level texture subdivision, split preview and combined GLB export.
Portable optimized-copy preparation is also implemented. Exact cross-region mip/
normal reproduction and native isolation beyond the admitted working set remain
future work; neither is promised by enabling optimization.

## Selected portable optimization route

The user approved portable GLB with an explicit optimized-copy option. Preserve
appearance remains the default. An optimized-copy profile allows regenerated
crop mipmaps and normalized clipped normals, including a geometric-normal
fallback at a zero interpolant. Base image pixels/resolution, geometry coverage,
materials and original downloads remain intact. The policy is retained through
folder/GLB export and reopen; it is never inferred from a failed exact job.
Current PNG crops cannot reproduce every original mip boundary or smooth-lighting
interpolant exactly, so the UI explains the choice before preparation and shows
the recorded policy on preview. Other format/working-set failures remain explicit.
See the
[native boundary assessment](NATIVE_PREPARATION_BOUNDARY.md) for the tested cases.
