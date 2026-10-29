# Project-based MessEarthKit workflow

Status: milestones 1–4 implemented: app files, project library/Settings, MapKit
confirmation, resumable Download, automatic preparation and whole-region Metal
composition. Focused checks and the milestone-4 macOS build passed.
The location model/lifecycle stage is implemented in schema 3, with basic
Add/Copy Location and detail-variant controls. The 18 app tests and macOS build
passed; the existing draft's one-time metadata preservation was explicitly approved
and applied through EarthAppFiles, preserving its editor values as one location.
Direct map move/resize/rectangle drawing is implemented; Export and end-to-end
GUI acceptance remain. Map editing verification is recorded in the handoff.
App-owned persistence is current-format only.
Updated: 2026-10-29 (America/New_York).
Owner: MessEarthKitExample. Reuse the MessEarthKit SDK's existing offline APIs.

## Objective

Present named projects containing locations, each with a fixed capture area and
detail variants, one whole-region preview and one exported file or folder per
operation. The location extension below supersedes the earlier project-level
capture editor described in milestones 1–4. Internal
source tiles, prepared parts and packing budgets remain
implementation details. Retain the ability to regenerate outputs from downloaded
sources offline.

This plan supersedes the example's split controls/models/preview workflow in the
[disk-backed acquisition plan](DISK_BACKED_CAPTURE_AND_LOCAL_USAGE_PLAN.md).
That plan's acquisition, integrity, preparation, appearance and codec contracts
remain in force. Prioritize this reorganization before the separate native-
decoder isolation prototype or further MessScene integration.

## Next approved milestone: locations and detail variants

Agreed on 2026-10-29. This section supersedes the address-bound project editor
and area-changing project variants described in the implemented milestones below.
Those descriptions record earlier checkpoints. The model/lifecycle and basic
controls and direct map gestures now follow the new hierarchy.

- **Project** owns its title and a collection of locations. The address field is
  a project map search: submitting a search moves the camera to a starting point.
  It does not move an existing location, create one automatically or rename the
  project. Searching New York and then Add Location creates another location there.
- **Add Location** creates a durable editable draft at the current map position.
  Its center, Width and Height define the requested rectangular ground footprint.
  They are independent of the searched address. The initial Detail control
  configures the first variant, rather than becoming a location-wide resolution.
- **Draft area editing** supports moving the box and changing Width/Height, with
  direct resizing synchronized with the numeric fields. Keep normal map browsing
  distinct from area editing and retain the left-controls/right-map arrangement.
  Camera motion alone never changes a location. Do not auto-recenter during a
  drag or perform reverse geocoding for every mouse update. Browse pans/zooms;
  Edit Area moves the box and exposes eight edge/corner handles; Draw Area replaces
  the draft rectangle. Live area previews update numeric fields without metadata
  writes; release commits once after identity/frozen-area checks. Done leaves area
  editing and restores map browsing. Escape, lost gestures or navigation discard
  an unfinished preview. Input errors do not move the
  camera or silently clamp numeric dimensions. Freehand polygons and rotation
  remain outside this milestone.
- **First Download Tiles** atomically freezes the location's center/Width/Height
  and records its first variant/source identity before Google transport begins.
  Freeze when the first acquisition is registered, not when it finishes. Pause,
  cancellation, transfer/preparation failure or deleting variants never unlocks
  an already frozen location. Validation failure before registration leaves a draft.
- **No-coverage recovery** offers Adjust Area on the incomplete variant card and
  below frozen editor dimensions. It opens/focuses an unlocked location copy with
  that attempt's original area/detail. Width/Height/center can change before an
  explicit new download. The failed journal stays intact and is never resumed
  against changed geometry. No automatic deletion, unlock or paid retry.
- **Add Variant** under a frozen location allows only Detail to change. All
  variants use that location's identical requested footprint; each freezes its
  own detail/request at registration and owns its download/resume status,
  source files, prepared references, preview and exports. Existing variants are
  immutable acquisitions. Another detail requires a new variant; changing export
  format/profile works offline from the same source when supported.
- **Copy Location** creates a new ID and an unlocked draft using the original
  area's settings. The copy can move/resize until its own first download starts.
  It begins without acquired/prepared artifacts or saved variants; its first
  variant has its own acquisition. Existing files remain with the original.
- **Search and selection** remain independent of acquisitions. Selecting,
  previewing or revealing a location/variant cannot silently replace a draft's
  area. Carry project, location, variant and operation identities through async
  callbacks so late lookup/download results cannot change another location or
  steal navigation. Only explicit Download Tiles/Resume enters Google transport.
- **Deletion** retains the existing native confirmations and centralized Trash
  policy. Project deletion includes all its locations; location deletion includes
  its variants; variant deletion preserves the location's frozen footprint.
  Removing the last variant from a frozen location leaves it frozen. Copy Location
  is the route to an adjusted area. Other locations, global settings/usage and
  unrelated files remain intact.

Keep location identity, draft/frozen lifecycle and shared geometry in app-owned
metadata. The SDK still consumes its existing immutable center/Width/Height/detail
request; no SDK persistence/UI dependency is needed for the new hierarchy. Keep
EarthAppFiles as the sole managed-root/metadata/authorization boundary.

Implement in bounded stages before milestone 5: first the typed location/variant
model and lifecycle/store operations; then wire map search, Add/Copy Location,
draft move/resize, location/variant cards and existing offline preview actions.
Verify freeze-before-transport, detail-only variants, independent copies,
search/camera isolation, paused/reopened identities and deletion of the last variant.
Reuse existing authored source and rendering fixtures; add no tests that merely
mirror button labels or reversible layout.

The runtime remains current-format only. A future schema change must explicitly
preserve existing source/prepared identities and saved work; do not add old-format
readers, automatic migrations, inferred projects or orphan adoption. This planning
checkpoint does not rewrite user project data or authorize a new one-time update.

## Navigation and screens

Use one navigation stack in the existing macOS app window:

Projects → Project Details (capture editor + MapKit) → 3D Preview → Export

Projects → Settings

Use toolbar Back navigation throughout. App screens, export options, errors and
progress must not be presented as sheets, popovers or custom overlays. Back does
not cancel a project job or discard edited fields. Remove the former manual
controls/model-browser/Metal workspace as the primary experience; do not merely place its full control panel on each route.
The user explicitly requested native destructive confirmations for project and
variant trash actions; those alerts are allowed.

### Projects

- App launch opens the saved project list. Each row has an editable project title
  independent of the address, with the address as secondary text. States include
  Draft, Downloading, Paused, Preparing, Ready and the specific failed operation.
  Distinguish a complete download from unavailable
  preparation/preview without labeling the original download incomplete.
- New is always available and is prominent in the empty state. It creates a
  durable draft and opens Project Details; no separate naming dialog is needed.
- Opening a project navigates to Project Details. A downloaded project offers
  View Preview without another download. Do not automatically select whichever
  source archive happens to be newest across the whole application.
- Settings is an app-level navigation destination accessible from Projects.

### Settings

- API key, Requests — last 30 days, Session requests, Clear counter and usage
  details live here. Existing tracking coverage/error explanations remain.
- One app-owned usage observer/store records attempts across every project,
  including while Settings is offscreen. Clearing statistics does not change
  projects, captures or exports. Project metadata never contains the API key.
- Reuse the Keychain loader and usage-store implementation at a URL supplied by
  the app-files owner. No old-ledger import, Core Data conversion or replacement
  of the SDK's SQLite journals/catalogs is part of this work.

### Project Details

- The capture form contains address field(s), detail choice, Width and
  Height in meters. Height describes the ground footprint and maps to the
  existing `depthMeters`; it is not building height. Resolved coordinates remain
  internal. Project Title is a separate field and never changes from address edits.
- Keep capture controls on the left and MapKit on the right in Project Details.
  The map remains visible for empty/invalid input; there is no separate map route.
  Update Map (or submitting the address) validates/resolves inline. Reuse a matching
  saved location on reopen without another lookup. Lookup failure/ambiguity stays
  inline; do not choose an arbitrary match or expose coordinates/API controls.
- Width/Height/detail edits rebuild the mapped selection immediately using the
  resolved address. Editing the address or entering invalid dimensions clears
  the footprint and disables Download. Re-resolve an edited address with Update
  Map. A Google key is not required for the map or address lookup.
- Show Resolving, Downloading and Paused progress plus explicit pause/resume/retry
  actions as needed. No request/tile/vertex/texture budget fields, technical
  model lists, manual Prepare Models action or legacy recovery panel here.
- Freeze the request associated with a download. Editing draft fields does not
  change or relabel its retained capture. A subsequent Download creates a new
  variant; append its frozen draft/location/request to the project and select it
  without overwriting another variant or its prepared reference. Capture variants
  lists detail/footprint/date/status. Each card owns Reveal in Finder, Preview or
  Resume Download, and Restore Capture Area; no separate Selected Capture panel
  or Use Capture step. Preview/reveal/resume preserve the draft/map. Restore
  Capture Area explicitly loads that variant's saved settings.
  No internal model-part selection is exposed here.
- A paused variant offers Resume Download with its frozen dimensions.
  A completed variant offers Preview, which prepares offline if necessary.
  Refresh Project in the toolbar flushes pending edits and reopens the recorded
  artifacts. It updates the retained owner instead of reusing a stale catalog.
  Surface preview errors here alongside the precise operation status.

### MapKit pane

- Display the resolved address, requested footprint polygon, Width/Height and
  detail beside the controls. Pan/zoom changes the camera only, never the request.
  Edits and review happen together; valid dimension/detail edits redraw in place.
- The map is native Apple MapKit; Google transport does not begin during address
  lookup or map confirmation. Download beneath Update Map starts acquisition explicitly.
  Missing credentials link to Settings with an inline explanation. Resume the
  current paused capture when it matches the confirmed request.
- Mark the polygon as the requested footprint; downloaded edge tiles can extend
  past it. Map display limitations for polar/very large footprints are explicit
  and do not change or cap the requested source area.
- Initialize the paused SDK archive offline and commit its project reference
  before any Google request. Resume uses that exact saved identity after restart.
- On successful source download, navigate to 3D Preview and prepare automatically.
  A navigation revision ticket admits completion only from the initiating Project
  Details route. Back, other projects, or leaving
  and returning invalidate the ticket without cancelling work. Completed data
  updates its project and never steals navigation.

### Preview

- Present the downloaded region as one scene in the Metal view. Frame the
  bounds of the whole capture and preserve the shared origin and all placements.
  Internal prepared parts may remain independent meshes/materials.
- Show preparation/loading progress inline until the scene is ready. Reuse
  matching prepared data after reopening; do not require repeated downloading
  or an explicit Prepare action. Keep orbit/zoom, Reset View and attribution.
- Refresh Preview reloads the saved project/current artifacts, then retries the
  visible scene or prepares offline if needed. It does not acquire again or
  infer substitute paths. Pending edits are saved first; Back never allows a
  refresh completion to change navigation or start a second load from old data.
- Export is at the toolbar's top right and navigates to the Export screen.
  Preview resource failure must not hide an otherwise supported offline export.
- The normal flow has no per-part preview pager, inclusion checkboxes or model
  selection. A single displayed part must never be presented as the full region.

### Export

- Export the entire current capture by default. Do not expose selected-model or
  subset management in the first version; SDK subset APIs remain available.
- Offer one GLB file or one model folder. The folder contains aligned internal
  parts and a root manifest; GLB can retain multiple meshes and materials inside
  one file. Neither option requires welding or material flattening.
- Output name, destination, preparation/export progress, errors and the completed
  result belong to this screen. Success offers a path and Show in Finder. Create
  a new output for each export and retain the project sources on every outcome.
- Preserve appearance is the default. Optimized copy is explicit and explains
  distant texture/seam/lighting differences. Any technical destination budgets
  belong to an optional Advanced export section or internal destination defaults,
  never the download form. Do not require users to set them for a normal export.
- Reprepare offline when the chosen output profile requires it. Export settings
  do not change acquisition requests or overwrite prepared data for another
  profile. Unsupported output/preparation keeps sources available for retry.
- Use the existing aggregate GLB preflight; one file remains subject to format,
  importer and destination limits. Offer the folder option when GLB cannot fit;
  do not silently change the chosen format, drop content or lower quality.
- USDZ and other codecs are future work. Adding an encoder does not inherently
  require downloading again; export cannot recover detail absent from sources.

## Centralized app-files policy

Adapt the MessScene app-files pattern through the adopted
[MessEarth app storage policy](../architecture/MESS_EARTH_APP_STORAGE.md).
Implement one injected `EarthAppFiles` owner before project persistence/navigation.
It centralizes the `Documents/MessEarthKit/` root, project/source/prepared/output
locations, settings/statistics, app metadata I/O and authorization lifetimes.
Views and feature services must not choose their own roots or bypass that owner.
SDK workers keep their existing bounded streaming and SQLite operations under
the host-supplied roots; no large payload copies through a whole-file Data wrapper.

Use a clean current-format project structure. Do not build legacy readers,
migrations, recovered-project discovery, alternate-root searches or silent
fallbacks. Missing/corrupt current data produces an explicit error. Existing
unrelated files are not moved or deleted by this planning work.

## Persistent project and job ownership

Projects are app-owned records, separate from immutable SDK source artifacts.
Use stable project IDs and a versioned, atomically saved manifest for each
project under the centralized app-files root. Schema 2 stores an independent title,
the editor draft/location, capture-variant snapshots (request, draft, location,
creation date and per-variant preparation), and selected capture ID. Current source/
prepared references derive only from that selection; they are not duplicate stored
pointers. Title/draft edits serialize together and do not rewrite snapshots. List summaries and file discovery are prepared off-main; views
consume cached values and send semantic actions.

Start with focused app owners for app files, the project store, navigation, settings,
project workflow, preview and export. Reuse the existing download/preparation/
export services. Do not grow `EarthWorkspaceViewModel` into a project database,
router and multi-scene renderer, or move these app responsibilities into the SDK.

- App/project ownership retains in-flight tasks and necessary file authorization
  independently of screen lifetime. Replace the workspace's current
  `onDisappear { cancelImport() }` behavior before introducing navigation.
- Keep one active acquisition/preparation/export pipeline at a time initially;
  project navigation remains available. Other projects can be opened without
  cancelling that work. A second job cannot steal or attach to the active job.
- Capture project ID, source identity and operation generation in async work.
  Late geocoding, progress, preparation or preview callbacks cannot update another
  project, an edited request or a replaced capture.
- Explicit cancellation preserves committed files. Relaunch reconstructs state
  from SDK journals/catalogs; a persisted “running” label is not proof that a job
  is still running. Resume network acquisition only through an explicit action.
- Resolve only current-format project records and their checked relative
  source/prepared/output references. Do not synthesize project records from older
  archives, search legacy folders or silently open the newest unrelated capture.
  Required missing files and unsupported schemas remain explicit load failures.
- Deleting projects, automatic retention cleanup, multiple concurrent jobs and
  a new general-purpose asset-import browser are outside this first version.

## Sources, preview and output are separate

The existing durable source archive already contains original GLBs, sanitized
hierarchy/transforms, origin, attribution and integrity/progress records. Google
output selection is not tied to our file format or per-model packing budgets.
Area/location and requested source detail are decided before acquisition;
preparation and packaging can change offline afterward.

Whole-region preview now uses a focused project-retained preview owner and worker,
separate from the old manual workspace. Two sequential passes consume one bounded
prepared model at a time. The first imports parts, queries Metal resource sizes
with allocator alignment and requested mip chains, then releases each CPU capture.
After aggregate admission, the second imports/uploads each part and composes its
GPU resources into one scene. It never builds an aggregate CPU capture or a combined
GLB for display. GPU materials contain shader values only, not encoded images.

The preview budget is the smaller of 1 GiB and half the device's recommended working
set. Admission includes existing device allocations (prior scene/in-flight overlap),
the full new scene, the largest part's upload/mipmap headroom and a 64 MiB viewport
reserve. Heap size queries are forecasts, not a second memory ceiling. During
upload, measured per-part overhead updates the projected full scene and largest
upload headroom before re-admission; estimates for remaining parts stay included.
Actual device use is checked against the same unchanged total budget. Device-budget
errors report current/allowed bytes separately from an allocation failure.
Any failure discards the unpublished scene; no partial part set is displayed. This
is conservative GPU admission, not total-process memory or native-crash isolation.
The two-pass approach trades repeated bounded import work for admission before
aggregate GPU upload; sources/prepared files are unchanged.

All parts preserve the shared geographic origin, materials/sampling/alpha and
attribution. The scene unions their bounds; camera reset fits the enclosing sphere
against both viewport axes. Jobs retain file access through both passes, verify
recorded capture/preparation identity, propagate explicit cancellation and publish
only to a still-visible matching project. Navigation releases displayed resources
without cancelling workers; hidden completion is discarded and can reopen offline.

The whole scene is available when it fits that working set. For larger captures,
show an explicit preview-unavailable explanation and retain supported exports;
do not cap or invalidate the raw download. On-demand streaming/overview rendering
is follow-up work, not an implied guarantee of this first reorganization. Do not
silently downsample imagery or enable Optimized copy to make preview fit. If exact
automatic preparation is unsupported, retain the download and route the user to
Export for an explicit appearance/profile choice.

## Implementation milestones

1. **Centralized app-files foundation (complete).** Implement the app storage policy with
   one injected `EarthAppFiles` owner, a namespaced root and current-only paths,
   atomic app metadata operations and explicit authorization lifetime. Replace
   independent app-side roots/file operations while retaining bounded SDK I/O.
   Done: stores/services accept locations/access from this owner; injected-root,
   confinement/access failures and atomic metadata round trips are verified.
   No old-root imports, file moves, fallback paths or navigation changes here.
   Verified by three headless storage tests and the macOS example Debug build.
   The old app inspection/recovery/calibration route was removed instead of
   adapting its independent paths or fallback imports. That milestone used a
   session project ID; milestone 2 now supplies persistent project records.
2. **Project library and navigation (complete).** Add durable current-format project records,
   Projects/New/Project Details routes and Settings using the app-files boundary.
   Move key/usage presentation into app-owned settings. Establish stable identity
   and navigation-independent job ownership before wiring the remaining routes.
   Done: create/edit/reopen drafts, reopen captures belonging to current-format
   projects, and navigate/back without losing saved state or current usage history.
   Initially implemented schema-1 records; projects now use schema 2 for title/
   capture variants while Settings remains schema 1. Serialized mutations preserve
   independent edits and explicit artifact references. Library/New/details routes
   and global Settings/Keychain access are implemented. Navigation retains project jobs; hidden preview scenes
   release resources after active work settles. This checkpoint preceded Download
   wiring, now implemented by milestone 3. Seven app persistence/
   storage tests and the macOS example Debug build pass; GUI acceptance is pending.
3. **Map confirmation, Download and automatic preparation (complete).** The user
   requested a MapKit preview before download, then a combined editor/map screen.
   Update Map resolves in place; Download Tiles below it starts the current mapped
   selection. Early offline archive creation
   and project reference persistence precede transfer. Paused jobs resume by ID,
   preparations run offline automatically, and source success remains distinct
   from preparation/preview failure. Back does not cancel or allow stale navigation.
   Ten app tests (18 cases), the SDK resume test (3 cases) and the example build
   passed at that checkpoint. The combined-editor follow-up updated the existing
   selection/navigation checks (nine cases) and passed the app build. Milestone 4
   replaces its one-model preview; no live/GUI run was performed.
4. **Whole-region Metal preview (complete).** Compose all
   ready prepared parts into one scene with two-pass GPU admission, full bounds/
   camera framing, worker/access lifetime and capture/preparation identity checks.
   New GPU materials retain no encoded source payloads. Fourteen headless app tests
   (27 cases) pass, including a three-part authored fixture, texture base pixels/
   mip levels, admission before upload, cancellation during upload, hidden/late/
   replaced-source publication and retained source/prepared files. The macOS
   example Debug build and source membership checks pass. No live GUI run.
5. **Whole-capture Export screen.** Route Export from the toolbar, select one
   GLB/folder, manage appearance/profile choices and produce one new output.
   Complete the approved location extension above first; Export targets a variant
   within its frozen location.
   Resolve the destination interaction below before external-save integration.
   Done: both outputs reopen with complete coverage, placement, materials,
   attribution and profile; profile changes add zero network requests.
6. **Workflow acceptance and removal of the old primary UI.** Verify the complete
   project flow and recovery across navigation/relaunch. Remove superseded split
   panels/manual steps after replacement routes work. Add no compatibility route
   back to the old UI or recovery panels. Update README to describe shipped screens.

Complete/checkpoint one bounded milestone before starting the next. Implementation
was authorized after the plan; no live requests or app launch were authorized.

## Verification and remaining interaction detail

- For documentation-only updates: inspect the diff, links and whitespace without
  a build. Implementation uses the focused checks below.
- Implementation checks should target distinct current project persistence,
  file-policy/confinement/schema rejection,
  wrong-project/stale callbacks, navigation versus explicit cancellation,
  source/preparation completion boundaries and whole-scene placement/coverage.
  Reuse existing local fixtures, injected transport and SDK verification helpers.
  Avoid new per-screen tests that merely mirror reversible view layout.
- Retain existing acquisition/resume, raw-byte integrity, request counting,
  appearance permission and folder/GLB round-trip coverage. Run affected focused
  checks and the macOS example build at each meaningful boundary; a full SDK
  gate is warranted only when shared package contracts change.
- UI acceptance must check toolbar navigation, empty/saved projects, inline
  progress/errors, complete-region framing and Export. A build alone does not
  prove these; app launch/live-service acceptance requires a separate request.
- Native confirmations for project/variant deletion are explicitly allowed;
  other app screens retain the no-overlay rule. Whether that rule also
  excludes native macOS folder/save authorization panels remains unresolved.
  Do not assume an exception: the Export route can first write to a project-owned
  output directory and reveal its result. Resolve external destination picking
  before adding a modal system picker or a new navigation-based file browser.
- Keep current source/native admission limits and public package boundaries.
  Exact cross-crop mip/normal delivery, stronger native isolation, arbitrary-size
  streaming, source-policy review, and Scene/root work are separate scopes.

## Title and capture-variant extension

Implemented independent project titles and schema-2 capture catalogs. Every
Download Tiles appends a variant; each owns its frozen area/detail and preparation.
Selecting one validates its files before changing selection. Invalid inactive
variants cannot displace a valid current one. Scene identity follows the new Metal
renderer even if SwiftUI batches a reset/reload. Current-source checks remain
unchanged, and one pipeline stays active at a time. Storage/workflow tests cover
completed/paused variants, title isolation, switching/restoring, wrong-selection
callbacks and preservation of raw artifacts.

The user explicitly approved a one-time metadata update of the existing project
while the app was closed. It was validated, backed up, atomically rewritten through
EarthAppFiles and reopened with the same source/prepared references. This is not a
runtime legacy reader/migration path. Other unreferenced folders remain untouched.

## Next exact action

The schema-3 model/lifecycle, basic controls, saved-project preservation and map
editing are implemented. Finish/checkpoint the current map stage after its tests
and macOS build pass, then stop. On continuation implement milestone 5: Export for
one whole variant, independent of preview success. Inspect the existing SDK folder/
combined-GLB exporter and preflight; offer a new project-owned output with explicit
appearance policy, inline progress/result/reveal. External destination picking
remains unresolved; do not assume a modal picker exception.
