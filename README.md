# MessEarthKit

A standalone Swift package and macOS example app for preparing textured
geographic 3D assets. It supports native GLB/Draco decoding, local 3D Tiles
assembly, durable Google Photorealistic 3D Tiles downloads, source-folder save/reopen,
immutable CPU assets, combined GLB export, and a Metal preview. USDZ delivery
remains optional future work. A real **200 × 200 m, 4 m detail** capture at 613 Race St,
Cincinnati has been decoded, saved, and reopened with matching geometry:
**152 meshes, 184737 triangles, 8.2 MB** of retained source files. GUI interaction
and visual inspection remain manual checks.

## Run the example

Open `MessEarthKit/MessEarthKit.xcodeproj`, select **MessEarthKitExample / My Mac**,
and Run. The existing project links the root Swift package; the app module is
named `MessEarthKitExample` to distinguish it from the library module.

The app opens a **Projects** library with **New** and **Settings** in the toolbar.
New creates a saved draft and opens Project Details with a separate Project Title,
Address, Detail, Width and Height. Edits save automatically, including incomplete
input. Renaming a project leaves its address, capture selections and source files
unchanged. Toolbar Back preserves edits and project-owned
jobs. Current project files reopen across launches; invalid files are reported
without replacing them with empty projects or scanning older storage roots.
Each home row has a trash button. Confirming **Move to Trash** removes the whole
project, including its variants and outputs. Settings and app-wide usage remain.

Settings holds the shared API key, request counter and usage details. **Save Key
in Keychain** explicitly persists an entered key; the secure field otherwise stays
in memory. Usage is app-wide and remains active while Settings is offscreen.

The capture flow is **Project Details → Download Tiles → 3D Preview**. Capture controls
stay on the left and MapKit stays on the right. **Update Map** (or Return in the
address field) resolves the address in place; saved matching locations reopen
without another lookup. Width, Height and detail update the mapped selection as
you edit. Changing the address or entering invalid dimensions clears the old
footprint and disables Download until the current selection is valid.

Map pan/zoom changes the camera only. The map/lookup does not require a Google
key or enter Google transport. Review the footprint, then press **Download Tiles**
directly beneath **Update Map** in the left controls. Whole intersecting tiles may
extend beyond the shown footprint. Very large/polar display limitations are explicit and do not alter the
requested dimensions.

The project saves a paused source journal/reference before any Google request.
**Pause Download** retains completed files; **Resume Download** reuses that exact
capture, including after relaunch. Download completion automatically prepares
models offline and advances to 3D Preview only while the initiating route is
still active. Back never cancels the job or lets a later completion steal navigation.
Preparation/preview failure retains the successful source download; **Preview**
or **Refresh Preview** retries offline without another download. Each new
**Download Tiles** saves a separate capture variant, so Preview, Standard and High
captures can coexist in one project. Each variant card lists detail, dimensions,
date and status, with **Reveal in Finder** and **Preview**, or **Resume Download**
for an incomplete capture. Progress and errors appear on that card. Preview and
Reveal preserve the current editor/map; **Restore Capture Area** explicitly loads
that card's saved address/area/detail. Preview prepares models offline if needed.
Each card also has a trash button with confirmation. It removes that variant's
downloaded tiles and prepared models while keeping the project, other variants
and editor settings. Deleting the last variant leaves a draft project. Deletion
is disabled while work is active; deleted files go to macOS Trash.
Editing detail or area to a new selection immediately shows a **New variant**
draft; **Download Tiles** saves it while retaining existing captures. The draft
does not start tile requests. Paused variants retain their individual resume journals.
The opened variant supplies the 3D view; other variants remain saved. **Refresh Project**
in the details toolbar flushes pending edits and reopens the project's recorded
source/prepared files. **Refresh Preview** performs that reload and retries the
visible scene (preparing offline if needed). It does not contact Google. Errors
name the failed stage, such as **Preview unavailable** or **Preparation failed**,
instead of the former generic Needs attention label.

Milestones 1–4 of the
[project workflow reorganization](docs/internal/plans/PROJECT_WORKFLOW_REORGANIZATION_PLAN.md)
are implemented. The 3D view composes the complete prepared region in one Metal
scene, preserves shared placement and attribution, and frames its full bounds.
A bounded preflight checks the aggregate geometry/textures/mipmaps plus upload
and existing-resource headroom before uploading the whole scene. Actual driver
allocations are rechecked against that budget with remaining parts included; a
small overrun of the forecast alone does not reject a fitting scene. Regions that
cannot fit produce an explicit preview error while retaining downloaded/prepared
files. Parts are imported one at a time and CPU source images are not kept in the
published scene. Leaving Preview releases displayed resources without cancelling
its worker; hidden completion can reopen offline.

The next planned app step is [locations with detail variants](docs/internal/plans/PROJECT_WORKFLOW_REORGANIZATION_PLAN.md#next-approved-milestone-locations-and-detail-variants),
followed by the Export screen. The SDK folder/combined-GLB exporters below remain
implemented independently of that remaining UI work. No live GUI acceptance has
been claimed by the headless checks and build.

When developing alongside MessScene in a MESS checkout, open the parent
**MESS.xcworkspace** instead. It includes the shared package and example project;
select **MessEarthKitExample** or **MessSceneApp** there. Close standalone project
or package windows before switching to the shared workspace so Xcode can release
their ownership of the local package.

## Capture and output contracts

The SDK downloads sources for a geographic location, footprint and requested
geometric error. Source selection and output preparation are separate. The project
map confirms the request before Download; output requirements are handled offline.

Normal downloads have no aggregate request, tile, source-byte, vertex, texture,
node-count or model-count ceiling. Files are streamed serially to disk, hashed,
and atomically published. Source metadata uses a separate 16 MiB JSON reader with
bounded nesting; endpoint, cycle, structural and GLB-container checks remain.
Disk space, connectivity, service quotas and available source detail can interrupt
acquisition. The SDK does not silently lower the requested detail.

Dimensions above 5 km are supported. Selection uses a conservative WGS84 surface
footprint, handles wrapped longitude and poles, and retains whole intersecting
tiles. Edge tiles can extend past the entered dimensions; mesh clipping and exact
building boundaries are not implemented. Width must fit within one Earth
circumference, depth within half a circumference, and all inputs must be positive
and finite. These are geographic validity checks rather than output model budgets.

The app-files owner retains new sources under
`Documents/MessEarthKit/projects/<project UUID>/sources/<capture UUID>/`. Each contains original GLBs, sanitized hierarchy
metadata, an indexed SQLite job journal, and (after download completes) a local
`tileset.json`. Keys, service URLs and session tokens are not persisted. Resume
restarts metadata traversal with fresh access and reuses SHA-256-validated payloads;
interrupted files retry from byte zero. Changed hierarchy or advertised source
versions require a new archive, preserving the previous files. Completed archives
are immutable; preparation writes separate results. A recorded project can reveal
its source archive through **Show Source Files**. The user controls retention of these folders.

`EarthModelPreparer` uses a file-backed planner and paged catalog. It inspects
one payload at a time, sorts placement records on disk, then writes and releases
each bounded model. There is no whole-capture source-byte/node or 64-model ceiling
on this path. SDK callers page the catalog and save it without decoding everything.

Prepared jobs live under
`Documents/MessEarthKit/projects/<project UUID>/prepared/<preparation UUID>/`.
Current project metadata records the selected source and prepared IDs/profile.
Reopening verifies the frozen request and source payload identity before exposing
the result. It does not substitute a newer directory when a required reference is
missing or corrupt. Original files are copied rather than hard-linked on export.

`EarthCaptureStore` saves an aligned model folder. `EarthGLBExporter` preflights
and writes one standalone GLB for a selected collection. The future project
Export screen will expose a whole-capture file/folder choice using these APIs.

Combined export retains independent meshes/materials, embedded image bytes,
sampler/mipmap settings, vertex colors, normals, UVs and shared local placement.
It does not weld meshes, resize images or decode the entire collection at once.
Geometry is written as ordinary uncompressed glTF, so the file can be larger than
the compressed source downloads. Origin, source/profile identifiers, selected
IDs, individual attribution and full/subset/partial coverage are recorded in
extras.messEarthKitCombinedAsset. The SDK restores these when reopening the GLB.

Preflight rejects aggregate geometry, texture, object/accessor, encoded file-size
or JSON working-set excess before creating output. It fingerprints selected
files; a changed input requires another check. Export streams one prepared model
at a time, removes its staging file after failure/cancellation, and never replaces
an existing destination or writes into a raw/prepared archive. Separate models
remains available when the combined asset exceeds the consuming app's limits.
The container follows the [glTF 2.0 GLB specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification);
its 32-bit length and the importer's 16 MiB JSON bound are checked explicitly.

Preparation defaults remain **2,000,000 vertices per model** and **256 MiB base-level
RGBA textures per model**. Each preparation freezes a versioned destination
profile with geometry/index, texture, source working-set and placement packing
targets. Reaching a model target starts another model. Changing the profile
and preparing again creates a new offline result; existing folders keep their
recorded profiles. Failed/cancelled preparations retain completed model folders
and the entire raw download. Export creates a new folder or GLB and never replaces
an existing destination.

`EarthPreparationAppearancePolicy.optimizedCopy` is an explicit opt-in choice
in the destination profile. It allows portable texture splitting that can change distant
texture appearance, crop seams and smooth lighting. Each cropped PNG keeps its
full-resolution decoded base pixels; original downloads are untouched. The
requested mipmap filter is retained and the consuming renderer generates new
mipmaps for each crop. New clipped normals are normalized approximations; a zero
interpolated normal falls back to the triangle's geometric normal. Invalid
degenerate surfaces still fail explicitly. This option does not resize imagery
or promise a smaller encoded file.

The selected policy is saved in preparation profiles, individual derivatives,
model folders and combined GLB metadata. Reopening an optimized result shows its
notice based on its recorded policy. Policy means permission
when subdivision needs it; it does not claim every model was changed. Leaving
the option off preserves the existing strict behavior.

When one source exceeds a geometry or index target, `EarthModelPreparer`
partitions its triangles into derivative GLBs. It preserves material assignments,
original texture bytes/sampling, normals, baked UV/node transforms and tile
placement. Repeated placements reuse the generated source parts. Each part uses
the same shared origin and can be previewed/exported through the paged catalog.
The importer honors the exact `messEarthKitSharedOrigin` already stored in aligned
model manifests. It validates that metadata and retains Double precision instead
of reconstructing the saved frame through an ECEF/geographic round trip. Invalid
declared origins reject explicitly; normal third-party tilesets derive their
frame from their bounding volumes.
Derived data lives inside the preparation folder; the raw archive stays immutable.

Geometry subdivision currently accepts at most **128 MiB source GLB**, **2 million
prepared source vertices**, and **6 million source indices**. These are a separate
source working set, not the destination's model budget. Compressed topology is
checked before native mesh decoding, using encoded counts rather than glTF
accessor claims. Edgebreaker uses a conservative three-corners-per-face point
bound, so some meshes can require a future source decoder path even when their
final merged point count is smaller. This guard does not bound every allocation
inside Draco or isolate a native decoder failure.

Textures exceeding a destination's edge or RGBA budget now split into
full-resolution lossless PNG crops for **non-mipmapped** nearest/bilinear
sampling. Triangles are clipped in baked UV space; repeat, mirrored-repeat and
clamp are handled independently on each axis. One-pixel gutters preserve bilinear
neighbors, including across wrapped image edges. Material factors, straight
alpha, interpolated vertex colors and geographic placement remain intact.

This crop path admits 8-bit RGB/grayscale source samples, up to **16,384 pixels
per edge** and **256 MiB decoded RGBA** in its source working set. JPEG decoding
is followed by lossless PNG encoding; it does not resize the image. **Preserve
appearance** rejects cropped mipmaps and changed lit-normal interpolation; unlit
or constant-normal lit triangles support exact base-level clipping. **Optimized
copy** admits regenerated crop mipmaps and approximate lighting as described
above. Unsupported pixel formats and destinations too small for required gutters
remain explicit failures in both modes. Resolution is never silently reduced.
Nearest ties at exact texel edges are
subject to Float UV precision, as in ordinary texture sampling. Per-triangle
repeat/clip work and the crop cache are bounded; those working-set failures also
retain the complete raw archive.

Sources exceeding the supported decode working set remain explicit failures of
preparation; acquisition stays **Downloaded**. See the
[native and texture preparation assessment](docs/internal/plans/NATIVE_PREPARATION_BOUNDARY.md).
General MessScene renderer streaming remains deferred. Internal derivative GLBs
remain distinct from the standalone combined GLB delivery path.

Application file access is centralized in the injected `EarthAppFiles` owner.
It defines the namespaced root, managed project/source/prepared/output locations,
small atomic metadata operations and external authorization lifetime. SDK workers
retain their bounded streaming, hashing, SQLite and artifact-publication paths.
See the [app storage policy](docs/internal/architecture/MESS_EARTH_APP_STORAGE.md).

Project metadata uses strict schema 2: an independent title, editable draft and
nullable resolved location, a capture-variant array and nullable selected capture ID.
Each variant freezes its request/draft/location and owns its prepared reference;
selection validates its recorded files before committing. Title and draft saves
share serialized atomic edits. Schema-1 app settings retain usage-detail disclosure
state separately; neither JSON format stores credentials. Unknown versions and
missing required keys fail explicitly. The app includes no legacy readers, automatic
migrations or source-folder inference.

## Local request counter

Settings shows **Requests — last 30 days**, a separate **Session requests**
count, and **Clear counter**. It tracks attempts from this example on this Mac,
across download, resume, failed/cancelled requests and explicit retries. Root/session attempts are counted separately from child JSON
metadata and GLB payload requests. Cached downloads, offline preparation,
preview, save, and reopening local files add no requests.

History persists across launches at
`Documents/MessEarthKit/stats/RequestUsage.sqlite`. The rolling window is exactly 30 × 24 hours;
older entries expire automatically. Tracking begins with this version's first
launch, and the display shows its start/clear time. Earlier requests, the CLI
probe, Google Console, and other apps/devices are not reconstructed or included.
**Clear counter** resets only these local statistics, including during a capture;
late completions cannot restore cleared requests. It leaves captures, keys, job
checkpoints, and Google usage unchanged.

**Usage details** shows metadata/GLB counts and completed, failed, cancelled and
pending/interrupted outcomes. A session request is a root-tileset attempt, not a
confirmed charge. These counters do not report billing-account usage, remaining
free allowance or the calendar billing month. History contains no keys, URLs,
session tokens, addresses or payloads. A storage problem is shown as incomplete
tracking and does not stop downloads.

The example imports/prepares on a worker. It uses event-driven Metal drawing and
does not observe vertex arrays or GPU resources through SwiftUI. Source
authorization stays active until the job finishes or observes cancellation.

## Google Maps API key setup

Live capture uses **Google Maps Platform → Map Tiles API → Photorealistic 3D
Tiles**, service `tile.googleapis.com`. Use your own Google Cloud project and API
key. You need a Google Cloud account, a project linked to an active billing
account, and permission to enable APIs and manage keys in that project. The
example uses the project associated with your key; no Cloud project ID is entered
in the app. Google's [Map Tiles setup guide](https://developers.google.com/maps/documentation/tile/get-api-key)
covers the Cloud requirements and credential screens. Steps checked October 28,
2026:

1. In the [Google Cloud Console](https://console.cloud.google.com/), select or
   create your project, then open **Billing** and link its billing account.
2. Open the API Library, find **Map Tiles API**, and enable it for that project.
   Selecting an API in a key's restrictions does not enable the API itself.
3. Open Google Maps Platform's **Keys & Credentials** page and create an API key
   dedicated to MessEarthKit. Name it so its purpose is clear.
4. Set the key's API restriction to **Map Tiles API** only, then save it.
5. For this direct-HTTPS macOS development client, set the application restriction
   to **IP addresses** and allow your Mac's public outbound IPv4/IPv6 addresses.
   Use the addresses Google sees through your router or VPN. Update them when
   your network changes. Temporary IPv6 addresses can rotate even on the same
   network, so a matching IPv4 address alone may not be enough. This follows Google's [web-service key restriction guidance](https://developers.google.com/maps/api-security-best-practices).
6. Open Google Maps Platform's **Quotas**, select Map Tiles API, and review the
   Photorealistic 3D Tiles daily root-tileset quota. Set a project limit appropriate
   for your usage. Google's [quota instructions](https://developers.google.com/maps/documentation/tile/usage-and-billing)
   describe how to change it. This project-level quota is separate from the app's
   **Maximum Requests**, which counts metadata and GLB requests within one capture.
7. Run **MessEarthKitExample**, open **Settings**, and enter the key string in the
   secure field. Use **Save Key in Keychain** to retain it across launches. The
   project screen offers Download once the current address/area is mapped. A newly enabled
   API can take a few minutes to become available. Enter the key string,
   not its Cloud resource ID or display name.

The Keychain generic-password item uses service
`com.jvclabs.MessEarthKit.MapTiles` and account `default`. This identifies the
app's credential independently of the Google Cloud project ID. A save failure is
reported explicitly. Keys stay out of project/settings JSON and source artifacts.

Common setup issues:

| Symptom | What to check |
| --- | --- |
| Google rejects the key | The app now distinguishes recognized IP, API restriction, API enablement, billing and quota errors without displaying the server body. Check both public IPv4 and IPv6 addresses; temporary IPv6 addresses can rotate on the same network. |
| HTTP 429 | Check the project's root-request quota and service rate limits. Changing region/detail does not reset them. |
| Capture vertex count exceeded | Prepare a completed archive offline with a fitting destination profile. A standalone import must fit the supplied vertex budget. |
| Capture decoded texture bytes exceeded | Prepare a completed archive offline with a fitting texture profile. A standalone import must fit its supplied texture budget. This counts base-level RGBA bytes, rather than compressed file size or total GPU memory. |
| Key field is empty after relaunch | Re-enter a session-only key, or check the optional Keychain item's service, account, and app access. |

## Import into MessScene

The MESS workspace's MessScene app can import saved capture folders through
**MODELS → EARTH CAPTURES → IMPORT**. Choose the folder containing `tileset.json`
and its local payloads, then press the imported thumbnail to place the model.
MessScene owns copies of the sources, geometry, and images; subsequent placement
and saved-scene reopening do not need the original folder or a Google key.
Partial source captures retain their incomplete report in the model library.
This first adapter supports opaque imagery with linear sampling and matching
wrap modes on both axes. It rejects vertex colors, transparency, unsupported
sampling, and meshes beyond MessScene's per-mesh capacity explicitly.
Combined GLB export is available in the example; USDZ export remains future work.

## Package use

Use `EarthSourceAcquisition` for durable raw downloads independent of codecs:

```swift
let region = try EarthDownloadRequest(
    center: EarthGeographicOrigin(latitude: 39.1026327, longitude: -84.515172),
    widthMeters: 200, depthMeters: 200, maximumGeometricErrorMeters: 4
)
let acquisition = EarthSourceAcquisition(apiKey: suppliedKey, requestObserver: observer)
let raw = try await acquisition.download(request: region, directoryURL: newArchiveURL)
// raw.state == .downloaded; raw.rootSourceURL references local source tiles.
// The parent directory must exist. Hosts retain its access and storage.

// After an interruption or restart:
let saved = try await EarthSourceArchive.open(directoryURL: existingArchiveURL)
let resumed = try await acquisition.download(
    request: saved.request, directoryURL: saved.directoryURL, resuming: true
)
```

`EarthSourceArchive.open` reads a small snapshot without network access or decoding.
Hosts that must record identity before the first request can call
`EarthSourceArchive.create(request:directoryURL:)` offline, persist its reference,
then call `EarthSourceAcquisition.download` with `resuming: true`. Creation requires
a new destination, emits no transport events and leaves a paused journal that can
be reopened even if the app exits before transfer starts.

An OS lock prevents concurrent writers. SQLite stores pending/completed payloads
and placement rows; depth-first traversal keeps one bounded metadata tree per
active hierarchy level rather than a whole-capture queue. The final manifest is
streamed from journal rows once. Restart reacquires metadata instead of persisting
expiring access URLs. Metadata fingerprints include advertised tileset versions;
unadvertised server changes at an identical URI cannot be inferred from local
files. Hosts must keep archive contents unchanged during acquisition/preparation.

For file-backed model preparation and export:

```swift
let profile = try EarthPreparationProfile()
let prepared = try await EarthModelPreparer().prepare(
    archive: raw, directoryURL: newPreparedFolderURL, profile: profile
)
let page = try await prepared.models(offset: 0, limit: 50)
if let first = page.first {
    let preview = try await prepared.importModel(id: first.id)
    // Only this model's bounded sources/decoded geometry are loaded.
}
let delivery = try await EarthCaptureStore().save(
    collection: prepared, selection: .all(), directoryURL: newExportFolderURL
)
```

`EarthPreparedCollection.open(directoryURL:)` reopens a catalog offline. Pages are
bounded to 256 items; total model count is not capped. Selection can be
`.all(excluding: ids)` or `.only(ids)`, including sparse IDs from saved subsets.
Ready collections record whether they cover the entire raw source. Partial jobs
can expose/export only their committed models with an explicit incomplete marker.
The destination must be outside the source archive/collection. A profile bounds
one payload/model's working set; it does not make native decoding unbounded.

New preparation profiles use format v2. Set
`appearancePolicy: .optimizedCopy` only for an explicit optimization choice;
the default is `.preserveAppearance`. Existing v1 profiles still decode with
preserved appearance, and v1 cannot declare optimization. Imported captures and
source collections expose the optional recorded `preparationProfile`.

For combined standalone delivery, preflight the selected collection first:

```swift
let exporter = EarthGLBExporter()
let combined = try await exporter.preflight(
    collection: prepared, selection: .all(), destination: profile
)
if combined.canExport {
    let glb = try await exporter.export(plan: combined, fileURL: newGLBFileURL)
}
// Otherwise show combined.issues and retain separate-model export.
```

`raw.sourceIdentifier()` returns the completed manifest's identity offline;
`prepared.matchesSource(raw)` additionally verifies recorded original payload
hashes for recovery. Neither decodes meshes or contacts the service. Keep source
and destination folder authorization alive through preflight and export. Plans
are immutable snapshots of selected input bytes; changed inputs require a new
check. Failed/cancelled writes remove only their own new staging file.

`EarthCaptureImporter.prepareCollection(fileURL:)` plans source-only model
sections before aggregate mesh decoding. Use `prepareCollection(precheck:)` to
reuse inspection downloads, or the immutable source-file overload in a host with
its own file-access boundary. Decode one section with `importSection(_:)`; save
all or a `collection.selecting(ids)` subset through
`EarthCaptureStore.save(collection:directoryURL:)`. Existing `importFile` and
`capture` APIs retain their single-capture aggregate limits. The reorganized
example will use the file-backed API above; these legacy APIs
remain available for clients that explicitly choose immutable byte collections.

Requires macOS 15.6+, Swift 6.2+, and Xcode. GLTFKit2 is pinned to **0.5.15** and
DracoSwift to **1.5.7**; SwiftPM resolves their pinned native framework artifacts.
The package has no sibling checkout paths or runtime Python/Blender dependency.
GLTFKit2's source and license are available in its
[upstream repository](https://github.com/warrenm/GLTFKit2/tree/0.5.15).
DracoSwift distributes the Apache-2.0 Draco library; see its
[source and notices](https://github.com/warrenm/DracoSwift/tree/1.5.7).
The private Objective-C++ bridge installs GLTFKit2's stateless decoder plugin
once per process. Decoding instances and output values remain request-owned.

```swift
import MessEarthKit

let importer = EarthCaptureImporter()
let capture = try await importer.importFile(fileURL: selectedURL)
// Read capture.meshes, materials, bounds, geographicOrigin, and sourceFiles.
// The host owns authorization, rendering, destination selection, and persistence.
```

Hosts with their own file-access boundary can instead supply immutable
`EarthSourceFile(relativePath:data:)` values to
`importer.importSourceFiles(sourceFiles:rootSourcePath:)`. Relative references,
geometry, and resource limits use the same decoder without opening source files.

```swift
let center = try EarthGeographicOrigin(latitude: 39.1026327, longitude: -84.515172)
let request = try EarthCaptureRequest(
    center: center, widthMeters: 200, depthMeters: 200,
    maximumSourceRequests: 1024, maximumSelectedTiles: 512
)
let limits = EarthImportLimits(maximumVertices: 4_000_000, maximumDecodedTextureBytes: 512 * 1024 * 1024)
// Legacy bounded capture-and-decode API (separate from raw acquisition).
let session = EarthCaptureSession(apiKey: suppliedKey, limits: limits)
let capture = try await session.capture(request: request) { progress in
    // Deliver throttled presentation updates to the host's UI actor.
}
let rootFile = try await EarthCaptureStore().save(capture: capture, directoryURL: newFolderURL)
```

For a staged estimate before native mesh decoding:

```swift
let check = try await session.precheck(request: request, recoveryDirectoryURL: newRecoveryFolderURL)
// Compare check.selectedTileCount, plannedSourceRequests, and optional geometry
// against host budgets. An incomplete check reports lower-bound counts.
if check.hasReusableSources {
    let prepared = try await EarthCaptureImporter(limits: limits).importPrechecked(precheck: check)
    // This import decodes meshes without further network access.
}
```

`matchesSelection` lets hosts retain completed sources when only budgets change.
Checkpoints from a completed precheck describe complete source coverage, even
when the estimated geometry exceeds the current import budget. Interrupted
prechecks retain the last completed source checkpoint with an interruption reason.

For durable recovery, pass `recoveryDirectoryURL: newRecoveryFolderURL` to
`capture`. The parent must exist and the recovery folder must be new. Each
selected GLB is written before an atomic `tileset.json` checkpoint is published.
The library still throws the original capture error; import that manifest to
prepare the completed tiles offline. `capture.incompleteReason` identifies an
unfinished snapshot and survives ordinary source-folder save/reopen. The marker
is cleared when source traversal finishes, before preview decoding. A later
vertex/texture-budget failure or cancellation during decoding still throws but
does not mark the completed source download partial. Those sources can be split
into models offline. The host owns directory authorization and retention;
checkpoints contain local references, without the service key or session URLs.

One importer is a serial actor. Each explicit request returns a result, throws a
typed `EarthImportError`, or throws `CancellationError`. Native decoder objects
do not escape the worker. Cancellation is cooperative: an active native decode
finishes before the next cancellation check, while Swift traversal/vertex loops
also check cancellation. The caller keeps source files accessible and unchanged
for the duration of the import.

## Current supported subset

Raw acquisition validates source hierarchy and GLB containers without decoding
their contents. The following describes offline preparation/import support.

- Self-contained glTF 2.0 `.glb`, default scene (or one unambiguous scene), static
  triangle primitives, interleaved accessors, unsigned indices, normalized vertex
  components, node transforms, and vertex colors. Missing normals produce flat
  triangle normals. Reflections reverse winding after normal transformation.
- Embedded PNG/JPEG base-color textures, UV set selection, texture transforms,
  sampling/wrap settings, color factors, metallic/roughness factors, unlit flags,
  sidedness, and opaque/mask/blend alpha modes. Omitted texture filters use linear
  sampling with linear mip selection; explicit unknown filters are rejected.
  The preview honors unlit color;
  lit materials use a simple directional preview, not a full PBR environment.
- Explicit 3D Tiles 1.0/1.1 hierarchies with Earth-centered placement, box/sphere/
  region root bounds, nested transforms, ADD/REPLACE refinement, and external
  local JSON tilesets, including the `3DTILES_content_gltf` declaration required
  for direct GLB content in 1.0. Local import reads the selected hierarchy's leaf content.
  Remote acquisition intersects the requested footprint and descends until its
  geometric-error target is met. Unavailable source detail is explicit. Legacy
  bounded capture/inspection can additionally stop at their configured budgets
  and retain marked partial snapshots.
- WGS84 geographic origin calculation and double-precision conversion to local
  meters before float vertices: East +X, Up +Y, North -Z. Original GLB and JSON
  bytes, relative paths, and attribution strings are retained in the result.

- `KHR_draco_mesh_compression` uses the native Draco decoder. A separately authored
  Khronos/Cesium Box fixture verifies it against the uncompressed reference,
  allowing the format's geometry/normal quantization.

Meshopt, other unverified extensions, sparse accessors, animation/skinning,
GPU instancing, extra material maps, implicit tiling, legacy tile containers, and
external GLB resource URLs are explicitly unsupported. No substitute geometry or
material is silently selected. The original payloads remain available for later
decoder/export improvements.

The importer bounds total source bytes, nodes, accessor/primitive counts,
prepared vertices, texture dimensions, and estimated base-level RGBA texture
bytes. These apply to preparation/import and the legacy capture API, separately
from raw acquisition and the eventual consumer's limits; they are not a claim about total process/GPU memory. Local tile references
must remain within the selected directory, including after resolving symlinks.
`EarthImportLimits.maximumVertices` defaults to 2,000,000. Supply the same limits
to `EarthCaptureSession` and `EarthCaptureImporter` to capture and reopen a larger
result. `maximumDecodedTextureBytes` defaults to 256 MiB. A destination profile freezes
vertex and texture budgets for each preparation/import job. This texture budget counts each imported
material/placement's base-color RGBA storage, including repeated images; it is
not a count of compressed downloads or a total process/GPU memory budget.

The legacy `EarthCaptureSession` API remains serial and cancellable.
`maximumSourceRequests` sets the
positive per-attempt request budget (default 512), including metadata and GLBs;
cached resource reuse does not consume another request. `maximumSelectedTiles`
sets the positive placement budget (default 256); reusing a downloaded GLB still
counts each selected placement. Interrupted-capture metadata records both chosen
budgets and the vertex/decoded-texture budgets. Other limits remain 64 hierarchy levels, 16 MiB
per response, and the configured node/total-byte budgets. These legacy budgets
do not apply to `EarthSourceAcquisition`. Requests stay on Google's HTTPS 3D Tiles
endpoint; redirects are refused. The ephemeral transport has no persistent cache
and reports status errors without credential-bearing URLs. Rewritten local
manifests retain selected transforms and bounds while removing service URLs,
keys, and sessions. Saving creates a new folder and removes its own incomplete
save output after failure/cancellation; existing destinations are never replaced.
Recovery checkpoints have separate retention: completed downloads survive both
failure and cancellation without increasing request or import limits.

The SDK’s `EarthCaptureSession.precheck` uses a new Google session and consumes metadata requests. Planned request
counts include unique JSON and GLB URLs, while selected-tile counts include reused
placements. Geometry inspection downloads complete GLBs; it is not a zero-download
check. It reads declared scene/accessor counts, accounts for repeated placements
and generated flat normals, and reads embedded image headers. Estimates do not
replace full import validation or guarantee peak memory usage. Geometry-buffer
estimates cover prepared CPU vertices and indices; texture estimates cover
base-level RGBA bytes, excluding mipmaps, decoder scratch space, and GPU copies.
Hosts retain a precheck snapshot and its optional recovery directory explicitly.
Importing that snapshot does not start another Google session. See the [3D Tiles tile schema](https://github.com/CesiumGS/3d-tiles/blob/main/specification/schema/tile.schema.json)
and [glTF accessors](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors).

## SDK offline estimates

Hosts can retain `await session.lastObservation` after a successful capture or
inspection and pass observations to
`EarthCaptureOfflineEstimate(request:observations:)`. The calculation reads only
supplied values and performs no I/O or network requests. It uses nearby
measurements at matching detail with broad area-based headroom; it is not a
confidence interval or a guaranteed workload/memory bound. The reorganized example
does not retain a separate calibration-history file or inspection/recovery UI.

Hosts can also pass `requestObserver:` to `EarthCaptureSession` to receive typed
`EarthRequestEvent` starts/finishes for actual transport attempts after cache and
budget checks. `EarthRequestUsageStore(fileURL:)` provides actor-owned local
history mechanics; the host supplies and authorizes the location. Its `record`,
`snapshot` and `clear` methods support a rolling counter without querying Google.
The example owns the store, presentation, refresh scheduling and retention UI.

## Verify locally

Keep compiler output outside the repository:

```sh
earth_build_root="${MESS_BUILD_CACHE_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds}/MessEarthKit"
swift test --scratch-path "$earth_build_root/swiftpm"
swift run --scratch-path "$earth_build_root/swiftpm" MessEarthKitIntegrationProbe
xcodebuild -project MessEarthKit/MessEarthKit.xcodeproj \
  -scheme MessEarthKitExample -destination 'platform=macOS,arch=arm64' build
```

The probe defaults to the bundled reference or accepts a local GLB/tileset path.
It reports source bytes, meshes, triangles, and local bounds as JSON. Its explicit
live mode accepts `--capture latitude longitude width depth error new-folder`,
reads the API key from stdin, and verifies that the saved capture reopens with
the same triangle count and bounds. Its new destination is also the recovery
folder; a failed capture leaves any published checkpoint there. JSON reports
include `isPartial` and, when present, `incompleteReason`. Normal tests
require no network or API key. Controlled source responses cover capture selection,
session propagation, resource budgets, save/reload, and cancellation. Fixture
coverage includes parameterized completion, default/custom request exhaustion,
completion above 512 requests, tile exhaustion and completion above 256
placements using one downloaded GLB, cancellation, invalid budgets, and
aggregate vertex/texture-limit and offline retry cases that verify durable
checkpoints, complete source coverage after decoding failure, partial coverage
after interrupted traversal, and existing-folder protection. Precheck
coverage adds JSON-only budget stops, selection completeness, reused placements,
flat-normal expansion, image-header estimates, offline reuse under revised vertex
budgets, and cross-job cancellation/exclusion.
Offline-estimator coverage checks insufficient references, local history roundtrip,
same-detail/nearby filtering, monotonic area scaling, and no added source requests.
Automatic-section coverage verifies vertex/texture partitioning, shared-origin
alignment, source-byte preservation, subset save/reopen, and independent model
folders.
Raw-acquisition coverage generates 4,100 unique payloads, including eight 17 MiB
files, crossing old request/tile/node and 128 MiB total/16 MiB response ceilings
without large committed fixtures. It checks task cancellation, refreshed access,
completed-file reuse, real publication failure, restart, altered files, atomic
publication recovery, advertised-version changes, writer locking, URI/cycle
confinement, parser/container rejection, credential absence and offline placement.
File-backed-preparation coverage generates 4,100 models over >128 MiB of source
payloads, verifies bounded paging and sparse-ID subset placement/reopen, and
checks each profile packing target independently. Cancellation/publication
failure retain committed models; unfit source working-set admission leaves the
raw archive complete. Repreparing with a
different profile, source/output confinement and non-aliasing export stay offline.
Geometry-subdivision coverage compares every ordered triangle attribute/material
against the authored source for plain, reflected/UV-transformed, flat-normal and
Draco cases, then checks subset export and cancellation. Encoded topology tests
use a valid independent Draco payload with small admission budgets plus malformed,
metadata and oversized-prefix cases, including a misleading glTF wrapper. These
do not claim successful decoding of a real >2M-point source or full native memory
isolation.
Texture coverage uses independent authored RGBA samples and a separate
linear-light nearest/bilinear sampler across seven wrap/filter combinations,
constant UVs, near-edge samples, geometry area/winding/color, profile compliance,
export/reopen and cancellation. Strict mipmap/varying-normal rejection remains
covered. Optimized cases check regenerated-mip filter retention, an independent
affine normal field and singular-normal fallback, folder/GLB policy round-trips,
legacy v1 defaults and unchanged original bytes. Gutter, 16-bit and repeat-work
failures retain raw downloads in either policy. No large image fixture or
per-frame imaging dependency was introduced. Google rejection coverage checks
reason specificity, bounded body parsing, credential privacy and HTTP status
propagation to request events.
Usage coverage tests the exact rolling cutoff, restart, duplicate delivery,
clear/in-flight completion, real retry attempts, cancellation before/after
transport entry, nested root-JSON classification, cache/offline reuse, explicit
storage failures and absence of credentials from SQLite files/sidecars.
The original orientation fixture is shared by the probe,
tests, and app; its independently specified coordinate/texture contract and
authoring script are documented in
[`Tools/IntegrationProbe/Fixtures/Orientation/README.md`](Tools/IntegrationProbe/Fixtures/Orientation/README.md).
The independent compressed fixture and its CC-BY-4.0 attribution are documented in
[`Tests/MessEarthKitTests/Fixtures/DracoBox/PROVENANCE.md`](Tests/MessEarthKitTests/Fixtures/DracoBox/PROVENANCE.md).

See the [initial plan](docs/internal/plans/MESS_EARTH_KIT_INITIAL_PLAN.md),
[disk-backed acquisition and local usage update plan](docs/internal/plans/DISK_BACKED_CAPTURE_AND_LOCAL_USAGE_PLAN.md),
[current handoff](docs/internal/handoffs/mess-earth-kit.md), and retained
[USGS alternative notes](docs/internal/research/USGS_BUILDING_RECONSTRUCTION_ALTERNATIVE.md).
