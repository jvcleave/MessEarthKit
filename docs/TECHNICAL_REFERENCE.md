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
- [Credentials](#credentials)
- [Troubleshooting](../README.md#troubleshooting)
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
| Check and write standard or optimized USDZ | `EarthUSDZExporter` |
| Read this SDK's saved USDZ export into CPU values | `EarthUSDZExportReader` |

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

### Prepared-folder display identity

Callers can attach a location and variant label to a committed prepared catalog:

```swift
let identity = try EarthCaptureIdentity(
    locationName: "Downtown", request: raw.request, detailName: "High"
)
try await EarthCaptureStore().recordIdentity(identity, collection: prepared)
```

This metadata-only worker operation writes optional `capture.info.json` files in
the catalog directory and each `models/model-N/` directory. It retains UUID-based
storage identities and preserves raw archives, GLBs, tilesets and placement.
The caller retains write authorization until the operation completes. Preparing
catalogs cannot be annotated; ready and partial catalogs contain committed models.
The identity request's centre must match the catalog's geographic origin.

The companion contains the flat Codable fields of
[`EarthCaptureIdentity`](../Sources/MessEarthKit/API/EarthCaptureIdentity.swift):
`formatVersion` (1), `locationName`, `request` and `detailName`. A model companion
also includes a positive integer `modelID`; the catalog companion omits it.
Each file is at most 16 KiB. Consumers can decode the public identity type and
the optional model ID without opening a project or decoding geometry. For
example, a display label can be `Downtown - High - Model 2`.

File-backed catalog export retains these companions, including original sparse
model IDs in a subset. Supplied invalid metadata or mismatched root/model
identity fails explicitly. Missing companions are allowed. Companion bytes are
separate from model payload estimates and geometry/texture budgets.

Annotation serializes artifact writes and publishes the catalog companion last.
Repeating the same complete identity avoids walking the model catalog. A changed
identity refreshes each model companion; cancellation leaves raw assets intact
and a later call can finish annotation. This API does not change scene- or
library-owned names in consuming applications.

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

For an explicitly reduced standard GLB, pass
`optimization: try EarthMeshOptimizationProfile(triangleFraction: 0.5, maximumErrorMeters: 0.1)`
to the same preflight. Nil preserves ordinary output. Reduction respects the
selected output channels, protected borders and transparent triangle order, using
the same offline meshoptimizer path as USDZ. Textures are not resized or re-encoded.
The requested target may be unreachable; the error is an algorithmic bound, not
a complete photometric or independent Hausdorff guarantee. No runtime compression
extension or meshoptimizer decoder is required.

`EarthGLBExportPlan.optimization` records the profile, source/output vertex and
triangle counts and achieved maximum error. Preflight fingerprints both source
and reduced geometry; writing repeats reduction per bounded model and checks the
same output before atomic publication. `exportedOptimization(fileURL:)` reads the
recorded result from bounded JSON without decoding binary geometry. It returns nil
for ordinary deliveries. Omitted-normal thumbnail parts use regenerated flat
normals, matching a standalone import. Acquisition/preparation sources stay intact.

### Export a standalone USDZ

```swift
let exporter = EarthUSDZExporter()
let optimization = try EarthUSDZOptimizationProfile(
    triangleFraction: 0.5, maximumErrorMeters: 0.1,
    maximumTextureDimension: nil // Keep original texture dimensions.
)
let plan = try await exporter.preflight(
    collection: prepared, selection: .all(), destination: profile,
    options: .full, optimization: optimization // nil for regular USDZ.
)
if plan.canExport {
    let result = try await exporter.export(plan: plan, fileURL: newUSDZFileURL)
    // result reports source/output counts, bytes and achieved maximum error.
    let metadata = try await exporter.metadata(fileURL: result.fileURL)
}
```

`EarthExportOptions` supplies the same five channel flags for GLB and USDZ.
`EarthGLBExportOptions` remains its public source-compatible spelling. Retain
source and destination authorization through checking and writing. USDZ plans
capture input fingerprints but compute final bytes/counts during writing.
Preflight conservatively admits original selection estimates against the
destination profile before optimization; a reduction target does not authorize
oversized input decoding.

### Read an exported USDZ

```swift
let reader = EarthUSDZExportReader()
let delivered = try await reader.read(fileURL: exportedUSDZURL)
// Convert the immutable meshes/materials into host GPU resources.
```

The caller owns authorization and keeps the file unchanged until the worker
returns. This reader supports the current USDZ dialect written by
`EarthUSDZExporter`, including optimized deliveries. It is not a general USD
importer. It reads actual archive geometry, embedded images and appearance;
it does not look up the original capture, preparation or an external native SDK.
Returned `EarthCapture.sourceFiles` retains the complete original USDZ bytes.

The root and dependency inventory, stored/aligned ZIP32 headers and CRCs are
checked. The known shader/property/primvar contract is validated explicitly;
unknown graphs fail without placeholder materials. Native Model I/O geometry
never leaves the worker. UVs return to the SDK's top-left convention. Raw RGBA,
base factors, unlit/sidedness, alpha masks/blending, wraps and mip intent survive.
The scalar appearance arrays are scanned without a per-scalar substring array.
When normals were omitted, the reader generates flat face normals in double
precision and admits the expanded vertex count against `maximumVertices`.
Positions, corner order, colors and UVs stay intact. Zero-area faces without
normals fail explicitly.

Default SDK reader admission is 512 MiB source, 2m decoded vertices, 2m triangles,
100,000 native nodes, 8192px textures and 256 MiB base texture pixels. The first
root text is bounded to 8 MiB, each appearance layer to 32 MiB and each encoded
image to 128 MiB. Callers can select other source, geometry, node and texture
ceilings through `EarthImportLimits`.
Native scratch, original bytes, material arrays and host/GPU copies add memory;
these limits are not a peak-RSS promise. Oversized, corrupt or unsupported exports
fail explicitly and the file remains intact. Cancellation is cooperative around
native loading and within Swift loops.

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
small nonzero triangles remain. A tileset payload containing only such omitted
triangles contributes its omission count without blocking usable geometry in
other payloads. Standalone GLBs and tileset imports without usable
triangles still fail, as do empty scenes and malformed or non-finite attributes.
Raw GLBs remain unchanged.

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
| `messEarthKitCombinedAsset` | Origin, source/profile identifiers, selected model IDs, individual attribution and full/subset/partial coverage. Optimized GLB also records `optimization` with profile, source/output counts and maximum error. |
| `messEarthKitCaptureIdentity` | Chosen name, full-precision request (center, ellipsoid height, dimensions, geometric error) and detail name. Supply `EarthCaptureIdentity` to preflight; reopen through `EarthCapture.identity`. |
| `messEarthKitExportOptions` | Included attributes/materials/images, alongside the texture-mode marker. |

Preflight checks aggregate geometry, textures, objects/accessors, encoded size and
JSON working set before output. It enforces the
[GLB container's 32-bit length](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification)
and the importer's 16 MiB JSON bound. Use separate models if a combined selection
exceeds the consumer's limits.

### Destination safety and retention

The example app also writes an optional `.glb.info.json` containing a model
summary matched by GLB size/SHA-256, geographic origin, saved capture identity
(name, full-precision centre, dimensions and detail) and an embedded PNG. SDK
callers opt in with `EarthGLBExporter.exportWithInfo`; the existing `export`
method remains GLB-only.
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

### USDZ output and optimization

`EarthUSDZExporter` writes selected prepared models in their shared local meter
frame (East +X, Up +Y, North -Z), with no recentering. Geographic subtraction has
already occurred at double precision during preparation. Ordinary USDZ does not
simplify, quantize or resize. It verifies source triangle order, positions,
normals, UVs and RGB after public Model I/O conversion. Vertex storage may be
reordered; triangle corner correspondence remains intact.

The package writes binary Crate `.usdc` geometry through public Model I/O,
worker-confined native objects, standard `.usda` appearance/dependency layers and
PNG/JPEG images. A streaming ZIP32 writer uses stored members, CRC verification
and 64-byte payload alignment. There is no ZIP deflate, ZIP64, meshopt extension
or runtime meshoptimizer decoder. Archive bytes including directories must fit
below 4 GiB and the archive supports at most 65,534 members. Binary geometry and
optional offline reductions provide size savings, which depend on the source;
varying appearance primvars remain text and textures often dominate file size.

The standard USD Preview Surface graph represents source metallic/roughness,
base factor, supported vertex tint, opacity/mask, sidedness and source images.
Unlit surfaces use zero diffuse/specular plus emissive color. USD bottom-left
UVs are written once from the SDK's top-left convention. `UsdUVTexture.scale`
is interface-only: a textured mesh can retain a constant vertex tint, multiplied
into its uniform scale. Textured meshes with varying RGB or effective alpha
fail preflight while vertex colors are selected. Choose GLB to retain that
appearance, or explicitly omit textures/colors. Untextured varying colors use
standard primvar readers. Materials are emitted per mesh so different constant
tints never overwrite a shared source material. Material omission is an
explicit neutral surface, while geometry and requested vertex channels remain.
Opaque sources ignore alpha; a zero mask cutoff is effectively opaque.
Texture bytes are copied exactly unless explicit resizing is requested.
Independent repeat/mirror/clamp axes are standard wrapS/wrapT. Nearest min/mag or
nearest mip filtering fails preflight when textures are included, because
standard USD Preview Surface does not preserve that contract. None versus linear
mip intent is retained in the exporter marker for readers supporting it; generic
USD viewers choose their own mip generation/filtering. Validate the intended
viewer when exact sampling is required.

Optimization requires an explicit `EarthUSDZOptimizationProfile`, independently
of the preparation profile. meshoptimizer 1.3 performs exact vertex remapping
over positions and selected output attributes, cache and fetch ordering, and
attribute-aware edge collapse. Omitted normals, UVs and vertex colors do not
create seams or contribute to the simplification error metric; in particular,
generated preview normals do not obstruct exports that omit normals.
Its target triangle fraction is in `(0, 1]` and its error bound is absolute local
meters. Selected normal/UV/color attributes participate in error and discontinuity
checks; mesh, material, tile and open UV borders are protected. No permissive seam
collapse, overdraw sorting, quantization or vertex updates are selected. Blended
meshes keep their topology and triangle order, using only lossless vertex
remapping/fetch. A zero error or fraction 1 skips simplification. The optimizer
removes exactly zero-area output triangles after nontransparent simplification
and before vertex compaction, using Double precision with no area cutoff. An
empty result fails export. The requested target may be unreachable. The reported
meshoptimizer error is an algorithmic
bound, not a complete photometric or independently measured Hausdorff guarantee.

An optional maximum texture dimension in `1...16384` resamples larger images to
fit their aspect ratio and writes PNG, preserving alpha. This is a selected
appearance change. Nil leaves image bytes/dimensions intact. The profile is saved
with the achieved counts/error; original acquisition and preparation files are
never replaced. The public exporter does not alter the source preparation policy.

The first root layer contains `customLayerData.string messEarthKitExport`, a
Base64-encoded JSON object bounded to 1 MiB. `EarthUSDZExportMetadata` version 1
records source identifier, double-precision geographic origin, optional capture
identity, source preparation profile, selected model IDs, coverage/completeness,
attribution, five channel flags, optional optimization profile, source/output
vertex and triangle counts, and achieved error. It contains no private paths or
credentials. `metadata(fileURL:)` reads only the bounded first stored root layer
and validates the marker; nil denotes an unrelated USDZ without the marker.
No separate information companion is required.

The per-model appearance layers add standard `displayOpacity` and untextured
shading primvars `earthDiffuseColor` and `earthOpacity`. Standard primvar readers
drive untextured color/opacity. Textured color uses a constant scale, never a
varying connection to an interface-only input. Surface
`messEarthKit:baseColorFactor` and `messEarthKit:unlit`, plus texture
`messEarthKit:vertexColorScale`, let a cooperating reader retain raw vertex
colors and separate material factors without double application. The reader
checks that the marker agrees with the standard scale and bound vertex colors.
Texture `messEarthKit:mipmap` records `none` or `linear`. These markers do not
replace the standard graph visible to other USD consumers.

A writer pages one prepared model at a time, rechecks fingerprints, stages only
its own output and atomically publishes a new file. It never overwrites an
existing destination. Cancellation before publication removes staging; completed
outputs remain durable. A decoded model, native conversion/readback, source
images and optimization buffers can coexist. Delivery file size is not an import
or peak-memory budget; consumers must define their own admission limits.


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

Hosts can decode an `EarthTexture` with
`decodedRGBA8(maximumDecodedBytes:)` on their worker. It returns top-left,
straight-alpha RGBA8 samples without color conversion or premultiplication,
including RGB stored in zero-alpha pixels. The default output-byte budget is
256 MiB; callers can select another positive budget. The 16,384-pixel edge limit
still applies. Common RGB/RGBA layouts use Accelerate byte conversion or reuse
already packed immutable RGBA storage. Nonopaque premultiplied samples remain
unsupported because unpremultiplication would alter quantized RGB values.
Unsupported pixel layouts throw `EarthImportError.unsupportedContent`;
dimensions or output bytes exceeding admission throw `EarthImportError.limitExceeded`.
This output budget does not bound ImageIO's transient allocations. See the
[native preparation reference](NATIVE_PREPARATION.md#base-level-texture-subdivision).

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
`record`, `snapshot` and `clear`. Hosts stop event/refresh work and call `close()`
before moving its storage; a later operation lazily opens a connection again.
The host supplies the authorized location,
presentation and refresh/retention policy; the store does not query Google.

## Example app storage and lifecycle

The injected `EarthAppFiles` owner centralizes managed roots, small atomic
metadata operations and external authorization lifetimes. SDK workers retain
bounded streaming, hashing, SQLite and artifact publication. See the
[app storage reference](APP_STORAGE.md).

Managed locations are relative to the configured root, initially
`~/Documents/MessEarthKit/`. **Settings → Storage → Move Storage…** moves the
existing library to an empty folder and persists its authorization for later
launches. [Storage relocation](APP_STORAGE.md#moving-storage) describes idle-work
admission, verification, cancellation and retained-copy handling.

| Content | Location |
| --- | --- |
| Raw source archive | `projects/<project UUID>/sources/<capture UUID>/` |
| Prepared job | `projects/<project UUID>/prepared/<preparation UUID>/` |
| GLB/USDZ export | `projects/<project UUID>/output/<export UUID>/` |
| Global export queue | `exportQueue.json` |
| Local request history | `stats/RequestUsage.sqlite` |

**Show Source Files** reveals a recorded archive. The user controls retention.
Reopening verifies the frozen request and source payload identity before exposing
prepared results. Missing/corrupt references fail instead of selecting another folder.

### Project metadata

Projects use strict **schema 5**; settings remain **schema 1**. A project records
independent title/search state, locations with automatic/custom names and
center/dimensions, permanent frozen timestamps, nested detail variants, editing
location ID and an independent active capture ID.

The location editor's **Auto** button restores persistent automatic naming for
existing locations, including custom-named and frozen locations. It resolves the
city at that location's saved centre and displays latitude/longitude to two
decimal places plus the selected footprint's width × height, rounded to whole
square meters: `Chicago (41.88, -87.63), 40,000 m²`. Invalid or incomplete dimension
edits omit the area until valid. Centre or dimension changes update automatic
names; manual edits restore custom naming. Capture requests and exported metadata
retain full coordinate precision. Lookup failure leaves the name intact, and stale lookup results
cannot overwrite a later name or centre change. The operation changes no capture
requests, downloaded files, prepared models or existing exports.

Every location header also offers **Rename…** independently of expansion and map
selection. Its dialog accepts a custom name or an **Auto** suggestion, and only
the **Rename** action saves the draft. Saving validates the original name and
centre before changing that location's name, and does not select it on the map.

Each variant owns its stable ID, current request/source/prepared reference and
earlier source attempts. Registration freezes a location and pins a source
atomically. Applying an area edit updates all pending variants together while
preserving IDs and earlier files; any completed capture locks the area. Confirmed
variant/location deletion includes every recorded attempt. Copies never reuse
source/prepared references. Title/search/location edits serialize, and activation
cannot overwrite a location draft.

Location expansion is session-only presentation state retained by each project
view model across navigation. The editing location starts expanded, other
existing locations start collapsed, and new or duplicated locations expand
without closing others. Refresh preserves choices for surviving location IDs;
deletion removes their expansion state. Collapsing does not change map selection
or job lifetime. Collapsed sections retain active progress/cancellation and an
error indicator. Expansion choices do not enter project metadata.

The library retains one download queue with two acquisition slots across all
projects and FIFO admission for additional variants. Each queued job pins its
project, variant and source attempt IDs, with its own task, progress, error and
pause/cancel action. A worker's slot is released after it stops. Completion and
preparation validate and update that variant without changing selection or
pending location edits. A cancelled queue entry never starts acquisition.

One preparation slot serves the download queue. A shared worker gate also
serializes native preparation with manual preview and export preparation. A
finished download releases its network slot before waiting for preparation.
The source becomes available for export after download; controls stay disabled
while its automatic preparation remains active. Export is hidden for incomplete
sources. Editing source detail/area and deleting active variants, their locations
or projects are refused; unrelated locations/projects remain usable.

The queue is session-only. Incomplete archives retain SDK checkpoints across
launches and resume only on an explicit action. Starting or resuming clears the
variant's previous job error and suppresses its old archive interruption while
the queued attempt is active. Fresh failures appear normally; other variants
keep their diagnostics. Late progress from earlier attempts is ignored.

Neither format stores credentials. Unknown versions and missing required keys
fail explicitly. The app has no runtime old-format reader, automatic migration
or source-folder inference.

### Export filenames and history

The app exports whole variants. Both variant and manual model-selection export
offer vertex colors, UV coordinates, materials and textures. New combined GLB,
optimized GLB, USDZ and optimized USDZ files omit normals; internal preparation and previews
retain normal generation. The public SDK retains its configurable normals option
and full defaults. Separate prepared-model folders preserve their source bytes.

Filenames combine the sanitized location name,
detail and included channels, for example
`Chicago_41.88_-87.63_40000m2_High_geom_vcol_uv_mat_tex.glb`.
Automatic filenames use two decimal places for coordinates and ungrouped whole
square meters followed by `m2`, calculated from the captured request's dimensions.
Every name includes `geom` (positions/triangle indices), followed by enabled
`norm`, `vcol`, `uv`, `mat` and `tex` tags in that order. Minimal ends in
`_geom.glb`. USDZ uses `.usdz`; optimized GLB/USDZ delivery adds `_optimized` before
the channel tags. The suffix uses the same captured plan options as the writer.
Earlier exports and SDK-authored files may include `norm`; their actual recorded
channels still drive history inspection and automatic rename suggestions.
The GLB scene/root node and USDZ metadata retain the unmodified chosen name; capture identity
metadata restores the authored name on import.

Each export offers **Rename…** and **Delete…** while project work is idle.
Rename accepts letters, numbers, spaces, periods, hyphens and underscores, keeps
the original `.glb` or `.usdz` extension and moves any GLB information companion
alongside it.
Names must fit within 245 UTF-8 bytes including the extension, reserving room for the
companion suffix. Rename preserves the export UUID, captured identity and file
contents. Delete requires confirmation, moves that export's output folder to
macOS Trash and removes its history entry. Missing files can also be removed
from history. Both actions leave the variant's source and prepared models intact.
See [storage lifetimes and failure handling](APP_STORAGE.md#source-preparation-and-export-lifetimes).

The rename sheet's **Auto** action resolves the city at the export record's
immutable capture centre and fills an editable city/coordinate/area/detail filename.
Area comes from that export's saved capture dimensions.
Content tags come from the exported file's recorded options; older GLBs without
those options omit the tags. Auto only prepares a draft: the current map,
location name, files and export history do not change until Rename is chosen.
Failed lookup retains the existing draft and shows an error. Dismissal or manual
editing cancels the lookup and rejects late results.

Export history retains its schema and texture flag; detailed channel choices
are stored in each new GLB or USDZ. Each history entry lists its recorded geometry,
normals, vertex colors, UV coordinates, materials and textures. The app reads
those choices from the GLB's bounded JSON header through
`EarthGLBExporter.exportedOptions(fileURL:)`, without decoding geometry or relying
on its filename or the current toggle settings. Optimized GLB also reads the
recorded reduction through `exportedOptimization(fileURL:)`, retaining its
settings and counts through rename and reopening. USDZ history reads the embedded
metadata through `EarthUSDZExporter.metadata(fileURL:)` and reports source/output
triangle counts, achieved meter error and whether optimization was selected. Missing files or absent choices
display unavailable contents; malformed output metadata reports a per-file error without
discarding history. The optional information companion is not required.

### Global variant export queue

Each downloaded variant offers **ADD TO QUEUE** beside its immediate export
button. Adding captures the current format, included channels, optimization,
source identity, preparation profile and names. The same variant can be queued
with different delivery choices; an identical pending/running request displays
**Already queued**. Subsequent control edits or renames do not modify that entry.

**QUEUE MANAGER** on the project home screen and beneath a project's locations
opens the same app-wide queue. Rows identify project, location, variant, format,
settings and status. Checkboxes select entries for **START** or **COLLECT…**:
START processes checked pending entries; COLLECT copies checked complete entries.
Select All/Deselect All and Remove Checked are available. Removing an entry
leaves exported files and project history intact. Up/down controls reorder the
stopped queue. Failed/cancelled rows offer Retry with their original request.
Completed rows offer **Show in Finder** for the saved export, including while
other queued items run. Reveal follows later history renames by export identity
and reports missing files explicitly.

Exports run one at a time and continue across navigation. An individual error
does not discard other results. **CANCEL** waits for the worker to stop and keeps
completed files; other entries remain pending. Pending rows can be unchecked or
removed before their turn, and the active row stays locked. Newly added or
retried entries wait for a later START. New project work waits until the batch
stops; the existing shared gate still serializes native preparation.

The versioned queue is saved across launches and reopens stopped. An interrupted
running attempt checks only its exact saved export UUID in project history, so
a committed tracked output remains complete. No capture transport or export is
started on launch, and no output directory scan adopts untracked files. Pending
queue saves and active work block storage relocation.

COLLECT selects a destination folder and copies completed output files plus
optional GLB companions into a new batch folder. Repeated filenames gain numeric
suffixes, applied to companions as well. Collection follows later history
renames by export identity, verifies copied bytes and leaves originals in place.
It never overwrites existing destination files. Missing/deleted results fail
explicitly. Cancelling a copy removes its unpublished batch; cancelling after
batch publication retains the completed copy. See the
[storage and collection contract](APP_STORAGE.md#global-export-queue-and-collection).

### Exported model viewer

Each available export-history entry offers VIEW. One dedicated app window uses
`EarthExportViewerViewModel` for selection/job state and
`EarthExportViewerService` for worker reads and GPU preparation. GLB uses
`EarthCaptureImporter`; USDZ uses `EarthUSDZExportReader`. Both feed the existing
Metal preview scene builder and renderer, with source unlit color or the same
simple lit-preview lighting used by capture previews. The viewer is not a
reference for every consuming app's PBR environment.

The picker lists saved files for the requested variant. Format, bytes, vertices
and triangles are cached from the delivered file; current export toggles do not
change an existing view. No source acquisition, preparation or re-export occurs.
Switching exports within the same variant preserves the camera for comparison.
Orbit/pan/zoom and Frame All share one camera; pan is enabled only for this
viewer, leaving capture-preview gestures unchanged.

A replacement clears the prior scene, cancels its job and waits for native work
to finish before starting the latest request. Stale completion cannot publish.
Close cancels work and releases the scene/renderer. An explicit retry rechecks
history and current file availability. GPU admission uses the existing automatic
working-set budget, including prior allocations, viewport and upload headroom;
no implicit decimation or texture reduction is applied to fit the viewer.

Whole-map decoding has viewer-specific source, vertex and decoded-texture
allowances derived from the remaining device budget and physical memory. It
does not apply the SDK's per-capture defaults to a combined exported map. Texture
edges remain bounded to 16,384 pixels and native nodes to 100,000. These are
conservative admission allowances, not a peak process-memory guarantee. File,
decode and GPU admission failures identify the viewer limit and its allowance.

The app-files owner holds an export read lease through decode/upload. Rename,
export deletion and project deletion reject mutations of files still being read;
unrelated metadata work remains available. After upload, GPU resources are
independent of the source file. See [export read ownership](APP_STORAGE.md#export-viewer-read-lifetime).

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

## Credentials

The optional Keychain generic-password item uses service
`com.jvclabs.MessEarthKit.MapTiles` and account `default`, independently of the
Google Cloud project ID. Save failures are explicit. Keys stay out of
project/settings JSON and source artifacts.

For setup, error messages, IP/subnet restrictions and recovery steps, see the
[README troubleshooting section](../README.md#troubleshooting).

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
