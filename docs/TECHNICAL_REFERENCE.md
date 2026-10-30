# MessEarthKit technical reference

SDK examples, file contracts, supported formats and local verification. Start with
the [app guide](../README.md) for setup, capture, preview and export, or its
[SwiftPM section](../README.md#swiftpm) for package installation.
Commands and source paths below assume the repository root.

- [Package use](#package-use)
- [Capture and output contracts](#capture-and-output-contracts)
- [Current supported subset and limits](#current-supported-subset)
- [SDK offline estimates](#sdk-offline-estimates)
- [Example app storage and lifecycle](#example-app-storage-and-lifecycle)
- [Local request counter](#local-request-counter)
- [Credentials and troubleshooting](#credentials-and-troubleshooting)
- [Verify locally](#verify-locally)

## Package use

The package requires macOS 15.6+ and Swift 6.2+. It includes GLTFKit2 0.5.15 and
DracoSwift 1.5.7 as local binary targets with universal macOS arm64/x86_64 slices.
Normal builds require no upstream package or release downloads. Matching native
implementation sources, including Google Draco 1.5.7, libktx 4.2.1 and embedded
cgltf, are preserved with licenses, immutable revisions and checksums in
[`ThirdParty/`](../ThirdParty/README.md). That reference also documents source
recovery and intentionally excluded optional upstream components. The package
has no sibling checkout paths or runtime Python/Blender dependency.

| Task | API |
| --- | --- |
| Import a local tileset or GLB into CPU values | `EarthCaptureImporter` |
| Download durable raw sources | `EarthSourceAcquisition` and `EarthSourceArchive` |
| Prepare and page independently loadable models | `EarthModelPreparer` and `EarthPreparedCollection` |
| Save a source/model folder | `EarthCaptureStore` |
| Check and write a standalone combined GLB | `EarthGLBExporter` |

Examples run in an asynchronous host context. Keys, observers and destination URLs
are supplied by the host, which owns file authorization, rendering and retention.
Keep source files accessible and unchanged until each operation completes.

### Import a local tileset or GLB

```swift
import Foundation
import MessEarthKit

let importer = EarthCaptureImporter()
let capture = try await importer.importFile(fileURL: selectedURL)
// Read capture.meshes, materials, bounds, geographicOrigin and sourceFiles.
// Convert the CPU values into the host's mesh and texture resources.
```

Pass a completed capture's `tileset.json`, an individual prepared model's
`tileset.json`, or a self-contained `.glb`. Direct imports use aggregate
[`EarthImportLimits`](#default-limits); use prepared parts for larger captures.
Hosts with their own file-loading boundary can supply immutable
`EarthSourceFile(relativePath:data:)` values to
`importSourceFiles(sourceFiles:rootSourcePath:)`. The same reference, geometry and
resource validation applies without opening source files.

### Download and resume raw sources

```swift
let region = try EarthDownloadRequest(
    center: EarthGeographicOrigin(latitude: 39.1026327, longitude: -84.515172),
    widthMeters: 200, depthMeters: 200, maximumGeometricErrorMeters: 4
)
let acquisition = EarthSourceAcquisition(apiKey: suppliedKey, requestObserver: observer)
let raw = try await acquisition.download(request: region, directoryURL: newArchiveURL)
// raw.state == .downloaded; raw.rootSourceURL references local source tiles.
// The destination must be new and its parent must exist.

// After an interruption or restart:
let saved = try await EarthSourceArchive.open(directoryURL: existingArchiveURL)
let resumed = try await acquisition.download(
    request: saved.request, directoryURL: saved.directoryURL, resuming: true
)
```

`EarthSourceArchive.open` reads a small snapshot without network access or
decoding. To record identity before the first request, call
`EarthSourceArchive.create(request:directoryURL:)`, persist its reference, then
download with `resuming: true`. Creation requires a new destination, emits no
transport events and leaves a paused journal that survives app exit.

### Prepare models and save a model folder

```swift
let profile = try EarthPreparationProfile()
let prepared = try await EarthModelPreparer().prepare(
    archive: raw, directoryURL: newPreparedFolderURL, profile: profile
)
let page = try await prepared.models(offset: 0, limit: 50)
if let first = page.first {
    let preview = try await prepared.importModel(id: first.id)
    // Only this model's bounded sources and decoded geometry are loaded.
}
let delivery = try await EarthCaptureStore().save(
    collection: prepared, selection: .all(), directoryURL: newExportFolderURL
)
```

`EarthPreparedCollection.open(directoryURL:)` reopens a catalog offline. Pages
contain at most 256 items; total model count is not capped. Selection can be
`.all(excluding: ids)` or `.only(ids)`, including sparse IDs from saved subsets.
Ready collections record whether they cover the entire raw source. Partial jobs
expose/export only committed models with an explicit incomplete marker.

`raw.sourceIdentifier()` reads the completed manifest's identity offline.
`prepared.matchesSource(raw)` also verifies original payload hashes. Neither
decodes meshes or contacts the service. See the
[preparation contract](#preparation-and-appearance) for profiles and subdivision.

### Export a standalone GLB

```swift
let exporter = EarthGLBExporter()
let combined = try await exporter.preflight(
    collection: prepared, selection: .all(), destination: profile,
    options: .untextured // .full is the default; .minimal or custom options also work.
)
if combined.canExport {
    let glb = try await exporter.export(plan: combined, fileURL: newGLBFileURL)
}
// Otherwise show combined.issues and retain separate-model export.
```

The destination profile applies to the **combined selection**, independently of
the collection's per-model profile. Keep source and destination authorization
alive through preflight and export. A plan captures selected input fingerprints,
options and the exact output byte count when export is possible; changed inputs
require a new preflight. See [combined GLB output](#combined-glb-output) for
attribute choices and metadata.

### Bounded capture and in-memory collections

`EarthCaptureSession` combines acquisition and decoding under explicit aggregate
budgets. These older APIs remain available for clients choosing immutable byte
collections; the example app uses durable acquisition and file-backed preparation.

```swift
let center = try EarthGeographicOrigin(latitude: 39.1026327, longitude: -84.515172)
let request = try EarthCaptureRequest(
    center: center, widthMeters: 200, depthMeters: 200,
    maximumSourceRequests: 1024, maximumSelectedTiles: 512
)
let limits = EarthImportLimits(
    maximumVertices: 4_000_000, maximumDecodedTextureBytes: 512 * 1024 * 1024
)
let session = EarthCaptureSession(apiKey: suppliedKey, limits: limits)
let capture = try await session.capture(request: request) { progress in
    // Deliver throttled presentation updates to the host's UI actor.
}
let rootFile = try await EarthCaptureStore().save(
    capture: capture, directoryURL: newFolderURL
)
```

For inspection before native mesh decoding:

```swift
let check = try await session.precheck(
    request: request, recoveryDirectoryURL: newRecoveryFolderURL
)
// Compare selectedTileCount, plannedSourceRequests and optional geometry with host budgets.
if check.hasReusableSources {
    let capture = try await EarthCaptureImporter(limits: limits)
        .importPrechecked(precheck: check)
    // No further network requests.
}
```

Precheck starts a Google session and consumes metadata requests. Geometry
inspection downloads complete GLBs, reads declared scene/accessor counts and
embedded image headers, and accounts for repeated placements and flat-normal
expansion. Incomplete counts are lower bounds. Estimates do not replace full
validation or guarantee peak memory: geometry estimates cover CPU vertices and
indices; texture estimates cover base-level RGBA, excluding mipmaps, decoder
scratch space and GPU copies.

Hosts retain snapshots and optional recovery directories explicitly.
`matchesSelection` permits reuse when only budgets change. A completed precheck
retains complete sources even if estimated geometry exceeds the import budget;
an interrupted one retains its last completed checkpoint and interruption reason.

For durable recovery, also pass `recoveryDirectoryURL:` to `capture`. Its parent
must exist and the folder must be new. Each selected GLB is written before an
atomic `tileset.json` checkpoint. The original error still throws; import the
checkpoint offline to recover completed tiles. `capture.incompleteReason`
survives source-folder save/reopen. Traversal completion clears the marker before
decoding, so later budget failures or decoding cancellation leave complete sources.

For source-only sections, call `EarthCaptureImporter.prepareCollection(fileURL:)`,
`prepareCollection(precheck:)` or `prepareCollection(sourceFiles:rootSourcePath:)`.
Decode with `importSection(_:)`; save all or a `collection.selecting(ids)` subset
with `EarthCaptureStore.save(collection:directoryURL:)`. Planning precedes aggregate
mesh decoding, but these byte-backed APIs retain their source/collection bounds.

## Capture and output contracts

### Raw acquisition and geographic selection

`EarthSourceAcquisition` selects sources from a geographic center, footprint and
requested geometric error. Selection and output preparation are separate; a
download never silently lowers requested detail to fit an output budget.

Raw acquisition has no aggregate request, tile, source-byte, vertex, texture,
node-count or model-count ceiling. Payloads stream serially to disk, are hashed
and atomically published. Metadata has a separate **16 MiB JSON limit** with
bounded nesting, endpoint, cycle, structural and GLB-container checks. Disk
space, connectivity, service quotas and available source detail can interrupt it.

Dimensions above 5 km are supported using a conservative WGS84 surface footprint,
including wrapped longitude and poles. Intersecting tiles are retained whole, so
edge geometry can extend past the requested rectangle. Mesh clipping and exact
building boundaries are not implemented. Width must fit within one Earth
circumference and depth within half a circumference; dimensions and geometric
error must be positive and finite.

Archives retain original GLBs, sanitized hierarchy metadata, a SQLite job journal
and, on completion, a local `tileset.json`. Keys, service URLs and session tokens
are excluded. An OS lock prevents concurrent writers. Depth-first traversal keeps
one bounded metadata tree per active hierarchy level; the final manifest streams
from journal rows.

Resume reacquires metadata with fresh access and reuses SHA-256-validated payloads.
Interrupted files restart from byte zero. Changed hierarchy or advertised source
versions require a new archive, preserving earlier files. Unadvertised server
changes at an identical URI cannot be inferred locally. Completed archives are
immutable; preparation writes separate results.

### Preparation and appearance

`EarthModelPreparer` inspects one payload at a time, sorts placement records on
disk, and writes/releases each bounded model through a paged catalog. There is no
whole-capture source-byte/node or 64-model ceiling on this path.

A versioned `EarthPreparationProfile` freezes geometry/index, texture, source
working-set and placement targets. Reaching a packing target starts another
model. [Defaults](#default-limits) include **2,000,000 vertices** and **256 MiB
base-level RGBA textures per model**. A different profile creates a new offline
result. Failed/cancelled jobs retain completed models and the entire raw download;
unsupported source decoding leaves acquisition **Downloaded**.

When one source exceeds geometry/index targets, preparation partitions triangles
into derivative GLBs. It retains material assignments, original image bytes and
sampling when no texture split is needed, normals, baked UV/node transforms and
tile placement. Repeated placements reuse source parts. Parts share one origin;
derivatives remain inside the preparation folder, separate from standalone delivery.

Geometry subdivision admits at most **128 MiB source GLB**, **2,000,000 prepared
source vertices** (including flat-normal expansion) and **6,000,000 source
indices**. These source working-set limits are independent of destination budgets.
Compressed topology is checked before native decoding using encoded counts.
Edgebreaker uses a conservative three-corners-per-face point bound, so it can
reject a mesh whose final merged point count would fit. Admission does not bound
every Draco allocation or isolate native decoder failures.

Oversized textures can split into full-resolution lossless PNG crops. Triangles
are clipped in baked UV space; repeat, mirrored-repeat and clamp are handled per
axis. Bilinear crops have one-pixel gutters, including wrapped image neighbors.
The path preserves material factors, straight alpha, interpolated colors and
placement. JPEG samples are decoded then encoded as PNG without resizing.

Texture subdivision admits **8-bit RGB/grayscale samples**, at most **16,384 pixels
per edge** and **256 MiB decoded RGBA**. Unsupported pixel layouts, insufficient
room for gutters, and excessive repeat/clip work fail explicitly. The crop cache
is bounded. Exact nearest-sampling ties at texel edges remain subject to Float UV
precision.

The profile's `EarthPreparationAppearancePolicy` controls cropping behavior:

| Appearance policy | Texture cropping and lighting |
| --- | --- |
| `.preserveAppearance` (default) | Supports non-mipmapped nearest/bilinear crops for unlit or constant-normal lit triangles. Rejects cropped mipmaps and changed lit-normal interpolation. |
| `.optimizedCopy` (explicit opt-in) | Retains the requested mipmap filter while renderers regenerate mipmaps per crop. New clipped normals use normalized interpolation, with a geometric-normal fallback for a zero interpolant. Seams, distant filtering and smooth lighting can change. |

Both policies retain full-resolution decoded base pixels and leave originals
untouched. Unusable degenerate clipped surfaces still fail. Optimization grants
permission when subdivision needs it; it does not assert every model changed or
promise a smaller encoded file.

New profiles use v2. Existing v1 profiles decode with `.preserveAppearance` and
cannot declare optimization. The policy survives derivatives, model folders and
combined GLBs; imported captures/collections expose `preparationProfile` so hosts
can display the recorded notice. See the
[native and texture preparation reference](NATIVE_PREPARATION.md)
for implementation limits.

### Coordinates and generated normals

Local coordinates use meters: **East +X, Up +Y, North -Z**. Geographic origin
subtraction and transforms use Double precision before conversion to float
vertices. Parts must retain their shared placement rather than being centered
independently.

Aligned model manifests store `messEarthKitSharedOrigin`. The importer validates
and uses that exact Double frame instead of reconstructing it through an
ECEF/geographic round trip. Invalid declared origins fail; third-party tilesets
derive their frame from bounding volumes.

When source normals are absent, flat normals use double-precision source edges
before output-position rounding and the inverse-transpose node transform.
Exactly zero-area source triangles are omitted individually during this step;
small nonzero triangles remain. Scenes without usable triangles and malformed or
non-finite attributes fail explicitly. Raw GLBs remain unchanged.

`EarthCapture.omittedDegenerateTriangleCount` reports omissions, also retained in
derivative/combined GLB extras as `messEarthKitOmittedDegenerateTriangleCount`.
Subdivision records the source count once across its parts; repeated placements
count independently. The integration probe includes it in JSON output.

### Combined GLB output

`EarthCaptureStore` saves aligned model folders. `EarthGLBExporter` writes one
standalone GLB for a selected collection, retaining independent meshes/materials,
embedded images, sampler/mipmap settings, vertex colors, normals, UVs and shared
placement by default. It streams one prepared model at a time. Geometry uses
ordinary uncompressed glTF; output can be larger than compressed downloads.
The exporter does not weld meshes or resize images.

| `EarthGLBExportOptions` | Included data |
| --- | --- |
| `.full` (default) | Positions, triangle indices, normals, vertex colors, UVs, materials and images. |
| `.untextured` | The same vertex data and materials, without images. |
| `.minimal` | Positions and triangle indices. |
| Custom value | Select normals, colors, UVs, materials and images individually. Textures require UVs and materials; inconsistent choices fail. |

Placement, capture identity when supplied, and attribution survive all options.
Omitted vertex channels occupy no binary space; omitting textures makes the output
texture estimate zero. Source loading still uses the collection's original bounded
profile. Omitting normals, colors or materials can change shading, tint or sidedness.

The output records these keys under GLB `extras`:

| Key | Contents |
| --- | --- |
| `messEarthKitCombinedAsset` | Origin, source/profile identifiers, selected model IDs, individual attribution and full/subset/partial coverage. |
| `messEarthKitCaptureIdentity` | Chosen name, full-precision request (center, ellipsoid height, dimensions, geometric error) and detail name. Supply `EarthCaptureIdentity` to preflight; reopen through `EarthCapture.identity`. |
| `messEarthKitExportOptions` | Included attributes/materials/images, alongside the texture-mode marker. |

Preflight checks aggregate geometry, textures, objects/accessors, encoded size and
JSON working set before output. It enforces the
[GLB container's 32-bit length](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification)
and the importer's 16 MiB JSON bound. Use separate models if a combined selection
exceeds the consumer's limits.

### Destination safety and retention

The example app also writes an optional `.glb.info.json` containing a model
summary matched by GLB size/SHA-256 and an embedded PNG. SDK callers opt in with
`EarthGLBExporter.exportWithInfo`; the existing `export` method remains GLB-only.
See [the companion contract](GLB_INFO.md) for fields, resource limits and consumer
behavior. Companion failures retain the published GLB and report a warning.

Prepared-collection save/export requires a new destination outside its raw/prepared
archives. Existing destinations are never replaced. Model-folder exports copy
original files rather than hard-linking them. Failed/cancelled saves remove their
own incomplete output; GLB writes remove their staging file. Acquisition
checkpoints and committed prepared models have separate retention and survive
interruption.

### Isolation and cancellation

One importer is a serial actor. Imports return immutable Sendable CPU values,
throw a typed `EarthImportError`, or throw `CancellationError`. Native decoder
objects stay on the worker. The private Objective-C++ bridge installs GLTFKit2's
stateless decoder plugin once per process; instances and output remain request-owned.

Cancellation is cooperative. An active native decode finishes before the next
check; Swift traversal and vertex loops also check cancellation. Hosts retain
file authorization until work finishes or observes cancellation.

## Current supported subset

Raw acquisition validates hierarchy and GLB containers without decoding content.
Offline import/preparation supports:

| Format or feature | Supported behavior |
| --- | --- |
| glTF 2.0 `.glb` | Self-contained files; default scene or one unambiguous scene; static triangle primitives, interleaved accessors, unsigned indices, normalized vertex components, node transforms and vertex colors. Missing normals generate flat normals; reflections reverse winding. |
| Materials and images | Embedded PNG/JPEG base-color images, UV set selection/transforms, sampling/wrap settings, color and metallic/roughness factors, unlit flags, sidedness and opaque/mask/blend alpha. Omitted filters use linear sampling with linear mip selection; unknown explicit filters fail. |
| 3D Tiles 1.0/1.1 | Explicit Earth-centered hierarchies, box/sphere/region root bounds, nested transforms, ADD/REPLACE refinement and external local JSON tilesets. Direct GLB content in 1.0 requires `3DTILES_content_gltf`. |
| Draco | Native `KHR_draco_mesh_compression` decoding. The independent Khronos/Cesium Box fixture checks against an uncompressed reference, allowing geometry/normal quantization. |
| Source preservation | Original GLB/JSON bytes, relative paths and attribution are retained; remote manifests are sanitized as described above. |

Local import reads hierarchy leaf content. Remote acquisition intersects the
footprint and descends until the geometric-error target is met; unavailable
detail fails explicitly. The example preview honors unlit color; lit materials
use simple directional lighting rather than a full PBR environment.

Unsupported content includes Meshopt, other unverified extensions, sparse
accessors, animation/skinning, GPU instancing, extra material maps, implicit
tiling, legacy tile containers and external GLB resource URLs. The importer
rejects these explicitly without substituting geometry or materials. Local tile
references must stay within the selected directory after symlink resolution.

### Default limits

Direct import and per-model preparation share these defaults, with different scope:

| Resource | `EarthImportLimits` (aggregate import) | `EarthPreparationProfile` (per model) |
| --- | --- | --- |
| Prepared vertices | 2,000,000 | 2,000,000 |
| Triangle indices | Bounded by source/accessor validation | 6,000,000 |
| Base-level decoded RGBA | 256 MiB | 256 MiB |
| Texture edge | 8,192 pixels | 8,192 pixels |
| Source bytes | 128 MiB | 128 MiB |
| Nodes | 4,096 | 4,096 per payload |
| Placements | Bounded by aggregate validation | 64 per model |

Node/accessor/primitive and metadata bounds also apply. Texture accounting counts
each imported material/placement's base-color RGBA storage, including repeated
images. These limits describe working sets, not compressed file size or total
process/GPU memory. Supply consistent `EarthImportLimits` to bounded capture and
reimport; use a destination profile to freeze preparation requirements.

The older `EarthCaptureRequest` adds per-attempt defaults of **512 source
requests** and **256 selected placements**. Cached reuse adds no request; a reused
GLB still counts each placement. It also retains 64 hierarchy levels, 16 MiB per
response and configured node/total-byte bounds. Interrupted metadata records the
chosen request, placement, vertex and texture budgets. These ceilings do not
apply to `EarthSourceAcquisition`.

Google transport stays on the HTTPS 3D Tiles endpoint, refuses redirects, uses no
persistent cache and reports status errors without credential-bearing URLs.
Rewritten manifests retain transforms and bounds while removing keys, sessions
and service URLs. See the
[3D Tiles tile schema](https://github.com/CesiumGS/3d-tiles/blob/main/specification/schema/tile.schema.json)
and [glTF accessors](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors)
for format definitions.

## SDK offline estimates

Retain `await session.lastObservation` after capture/inspection and pass observations
to `EarthCaptureOfflineEstimate(request:observations:)`. It performs no I/O or
network requests. Nearby measurements at matching detail provide broad area-based
headroom, not a confidence interval or guaranteed workload/memory bound. The
example app does not retain a separate calibration history or inspection/recovery UI.

`requestObserver:` on acquisition/session APIs delivers typed `EarthRequestEvent`
starts/finishes for actual transport attempts after cache/budget checks.
`EarthRequestUsageStore(fileURL:)` provides actor-owned local history through
`record`, `snapshot` and `clear`. The host supplies the authorized location,
presentation and refresh/retention policy; the store does not query Google.

## Example app storage and lifecycle

The injected `EarthAppFiles` owner centralizes managed roots, small atomic
metadata operations and external authorization lifetimes. SDK workers retain
bounded streaming, hashing, SQLite and artifact publication. See the
[app storage reference](APP_STORAGE.md).

Managed locations are relative to `~/Documents/MessEarthKit/`:

| Content | Location |
| --- | --- |
| Raw source archive | `projects/<project UUID>/sources/<capture UUID>/` |
| Prepared job | `projects/<project UUID>/prepared/<preparation UUID>/` |
| GLB export | `projects/<project UUID>/output/<export UUID>/` |
| Local request history | `stats/RequestUsage.sqlite` |

**Show Source Files** reveals a recorded archive. The user controls retention.
Reopening verifies the frozen request and source payload identity before exposing
prepared results. Missing/corrupt references fail instead of selecting another folder.

### Project metadata

Projects use strict **schema 5**; settings remain **schema 1**. A project records
independent title/search state, locations with automatic/custom names and
center/dimensions, permanent frozen timestamps, nested detail variants, editing
location ID and an independent active capture ID.

Each variant owns its stable ID, current request/source/prepared reference and
earlier source attempts. Registration freezes a location and pins a source
atomically. Applying an area edit updates all pending variants together while
preserving IDs and earlier files; any completed capture locks the area. Confirmed
variant/location deletion includes every recorded attempt. Copies never reuse
source/prepared references. Title/search/location edits serialize, and activation
cannot overwrite a location draft.

Neither format stores credentials. Unknown versions and missing required keys
fail explicitly. The app has no runtime old-format reader, automatic migration
or source-folder inference.

### Export filenames and history

The app exports whole variants. Filenames combine the sanitized location name,
detail and included channels, for example
`Chicago_41.87811_-87.62980_High_geom_norm_vcol_uv_mat_tex.glb`.
Every name includes `geom` (positions/triangle indices), followed by enabled
`norm`, `vcol`, `uv`, `mat` and `tex` tags in that order. Minimal ends in
`_geom.glb`. The suffix uses the same captured plan options as the writer.
The GLB scene/root node retain the unmodified chosen name; capture identity
metadata restores the authored name on import.

Each export offers **Rename…** and **Delete…** while project work is idle.
Rename accepts letters, numbers, spaces, periods, hyphens and underscores, keeps
the `.glb` extension and moves its optional information companion alongside it.
Names must fit within 245 UTF-8 bytes including `.glb`, reserving room for the
companion suffix. Rename preserves the export UUID, captured identity and file
contents. Delete requires confirmation, moves that export's output folder to
macOS Trash and removes its history entry. Missing files can also be removed
from history. Both actions leave the variant's source and prepared models intact.
See [storage lifetimes and failure handling](APP_STORAGE.md#source-preparation-and-export-lifetimes).

Export history retains its schema and texture flag; detailed channel choices
are stored in each new GLB. Each history entry lists its recorded geometry,
normals, vertex colors, UV coordinates, materials and textures. The app reads
those choices from the GLB's bounded JSON header through
`EarthGLBExporter.exportedOptions(fileURL:)`, without decoding geometry or relying
on its filename or the current preset. Missing files or absent choices display
unavailable contents; malformed output metadata reports a per-file error without
discarding history. The optional information companion is not required.

### Preview ownership

The app imports/prepares on a worker and uses event-driven Metal drawing.
SwiftUI observes prepared presentation values rather than vertex arrays or GPU
resources. File authorization remains active through completion/cancellation.

## Local request counter

Settings shows **Requests — last 30 days**, **Session requests** and
**Clear counter**. Counts include actual attempts from this example on this Mac:
download, resume, failures, cancellations and explicit retries. Root/session
attempts are separate from child JSON metadata and GLB payload requests. Cached
downloads and offline preparation, preview, save and reopening add no requests.

History persists across launches in the managed request database above. The
rolling window is exactly **30 × 24 hours**; older entries expire automatically.
The display shows tracking start/clear time. Earlier requests, the CLI probe,
Google Console and other apps/devices are excluded.

**Clear counter** resets only local statistics, including during capture; late
completions cannot restore cleared requests. Captures, keys, checkpoints and Google
usage remain intact. **Usage details** separates metadata/GLB requests and
completed, failed, cancelled and pending/interrupted outcomes.

A session count means a root-tileset attempt, not a confirmed charge. Counters do
not report billing-account usage, remaining allowance or a calendar billing month.
History contains no keys, URLs, tokens, addresses or payloads. Storage failures
show incomplete tracking and do not stop downloads.

## Credentials and troubleshooting

The optional Keychain generic-password item uses service
`com.jvclabs.MessEarthKit.MapTiles` and account `default`, independently of the
Google Cloud project ID. Save failures are explicit. Keys stay out of
project/settings JSON and source artifacts.

| Symptom | What to check |
| --- | --- |
| Google rejects the key | Check IP/API restrictions, API enablement, billing and quota. The app distinguishes recognized failures without displaying the server body. Check both public IPv4 and IPv6; temporary IPv6 addresses can rotate. |
| HTTP 429 | Check the project's root-request quota and service rate limits. Changing region/detail does not reset them. |
| Capture vertex count exceeded | Prepare a completed archive offline with a fitting destination profile. A standalone import must fit its supplied vertex budget. |
| Capture decoded texture bytes exceeded | Prepare offline with a fitting texture profile. Standalone import counts base-level RGBA, not compressed file size or total GPU memory. |
| Key field is empty after relaunch | Re-enter a session-only key, or check the optional Keychain item's service, account and app access. |

## Verify locally

Run from the repository root, using a stable SwiftPM scratch path outside the
checkout and normal Xcode DerivedData:

```sh
earth_build_root="$HOME/Library/Developer/Xcode/DerivedData/MessEarthKit"
swift test --scratch-path "$earth_build_root/swiftpm"
swift run --scratch-path "$earth_build_root/swiftpm" MessEarthKitIntegrationProbe
xcodebuild -project MessEarthKit/MessEarthKit.xcodeproj \
  -scheme MessEarthKitExample -destination 'platform=macOS,arch=arm64' build
```

If an enclosing workspace defines a build-cache location, set `earth_build_root`
to its package-specific directory. Use a distinct directory for concurrent
checkouts. The tracked [`.swiftformat`](../.swiftformat) defines formatting;
scope linting to changed Swift files and avoid broad formatting passes.

Normal tests use local fixtures without network access or an API key. Coverage
includes format/placement/material fidelity, bounded decoding and subdivision,
large disk-backed acquisition/preparation, restart and cancellation, destination
safety, credential privacy and request-counter lifecycles. See
[SDK tests](../Tests/MessEarthKitTests/) and the
[native preparation reference](NATIVE_PREPARATION.md#verification-and-limits)
for detailed cases and native-decoder coverage limits.

The probe uses the bundled reference by default or accepts a local GLB/tileset
path. JSON output includes source bytes, meshes, triangles, local bounds,
`omittedDegenerateTriangleCount`, `isPartial` and optional `incompleteReason`.
Explicit live mode accepts `--capture latitude longitude width depth error new-folder`
and reads the API key from stdin. It verifies saved/reopened triangle counts and
bounds; the new destination doubles as a recovery folder on failure.

Fixture contracts and provenance:

- [Orientation fixture and authoring script](../Tools/IntegrationProbe/Fixtures/Orientation/README.md)
- [Independent Draco fixture and CC-BY-4.0 attribution](../Tests/MessEarthKitTests/Fixtures/DracoBox/PROVENANCE.md)
