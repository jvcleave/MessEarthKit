# Native decoding and model preparation

MessEarthKit prepares downloaded 3D tiles as aligned model parts for a consuming
app's geometry and texture budgets. This reference describes native decoder
admission, subdivision and appearance limits. Start with the
[technical reference](TECHNICAL_REFERENCE.md#prepare-models-and-save-a-model-folder)
for API examples and [default import limits](TECHNICAL_REFERENCE.md#default-limits)
for aggregate-import versus per-model budgets.

## Native decoder admission

Before native mesh decoding,
[`EarthDracoAdmission.mm`](../Sources/EarthDracoBridge/EarthDracoAdmission.mm)
reads the Draco topology prefix with a constant-memory cursor. It checks the
signature, version, method, bounded metadata and conservative point/face counts
without allocating a mesh or count-sized vector. Both Swift admission and the
GLTFKit2 decoder plugin apply a 2,000,000-point/face ceiling. Post-decode checks
also apply.

Sequential encoding supplies point/face counts. Edgebreaker may duplicate points
at attribute seams, so admission uses three corners per face plus legacy added
vertices rather than trusting glTF accessor counts. This can reject a source
whose final merged mesh would fit. Metadata is limited to 32 nesting levels and
4,096 total entries/nodes. Malformed or unsupported structures fail explicitly,
while original raw files remain available.

This guard bounds topology admission. Attribute and entropy decoding still use
the native library; it does not provide a complete native-allocation bound,
sandbox or crash isolation. Native decoding returns a whole mesh. Cancellation
is cooperative: an active decode finishes before the next check. Hosts retain
file authorization until work finishes or observes cancellation.

## Geometry subdivision

[`EarthGeometrySubdivision`](../Sources/MessEarthKit/Tiles/EarthGeometrySubdivision.swift)
operates within a supported source working set: 128 MiB GLB, 2,000,000 prepared
vertices including flat-normal expansion, 6,000,000 indices, bounded metadata and
admitted native topology. One worker owns native objects and CPU arrays. A large
file-backed collection is processed incrementally rather than decoded in full.

Per-model destination budgets govern triangle partitioning. Parts remap referenced
vertices while retaining ordered winding, normals, colors, material factors,
alpha/unlit/sidedness, UVs and sampling. The source decoder applies node transforms,
reflected winding and UV transforms once. Tile transforms retain shared placement.
Original texture bytes remain unchanged when subdivision is unnecessary.

Derivatives retain source-payload identity, stay outside the immutable raw archive
and are journaled/reused for repeated placements. They enter the existing prepared
catalog and exporters. If a single triangle and its material/texture cannot fit,
preparation fails explicitly and retains originals and committed output. Texture
resolution is not lowered to satisfy a budget.

## Base-level texture subdivision

[`EarthTextureRaster`](../Sources/MessEarthKit/Tiles/EarthTextureRaster.swift)
reads supported ImageIO samples at the offline file-I/O boundary. Source admission
allows 16,384 pixels per edge and 256 MiB decoded RGBA. It requires supported
8-bit RGB/grayscale samples and avoids a premultiplied or color-converting drawing
context. Pixel layouts requiring lossy alpha unpremultiplication fail. Lossless
PNG output preserves decoded straight-alpha/base-color samples without resizing.
These figures are source working-set limits, not total process-memory guarantees.

[`EarthTextureSubdivision`](../Sources/MessEarthKit/Tiles/EarthTextureSubdivision.swift)
clips triangles in baked UV space using barycentric coordinates. Repeat, mirror
and clamp intervals are affine independently on each axis. Nearest sampling needs
no gutter; bilinear crops use one pixel of wrapped neighbors per side. Crops use
clamp and remapped UVs, preserving authored wrap behavior in geometry and pixels.

Each crop must meet destination dimension/RGBA budgets, and resulting geometry
still passes vertex/index/source-byte packing. The encoded-crop cache is 16 MiB.
Per-triangle work is bounded at 4,096 periods per axis, 65,536 axis intervals and
65,536 Cartesian candidate regions. Excess work, unsupported 16-bit/pixel layouts
or insufficient gutter room fail explicitly and retain sources.

## Appearance policies

**Preserve appearance** rejects mipmapped subdivision: independent crop mip
chains change filtering across regions, and the PNG contract does not carry shared
mip levels. It also rejects lit varying-normal clipping that changes normalized
normal interpolation. Unlit and constant-normal lit triangles support exact
base-level clipping.

**Optimized copy** requires explicit selection before preparation. It retains
the requested minification filter and permits consumers to generate each crop's
mipmaps, with normalized barycentric normals on clipped vertices. A zero normal
interpolant uses the geometric face normal; unusable degenerate surfaces fail.
Base image resolution stays unchanged, but seams, distant filtering and smooth
lighting may differ. This permission does not assert every model changed or
guarantee smaller files.

Profile v2 records the policy in derivatives, model folders and combined GLBs.
Profile v1 remains preserve-appearance. Imported captures/collections expose the
recorded profile for host presentation. See the
[preparation contract](TECHNICAL_REFERENCE.md#preparation-and-appearance).

## Verification and limits

Existing [SDK tests](../Tests/MessEarthKitTests/) use the authored
[orientation fixture](../Tools/IntegrationProbe/Fixtures/Orientation/README.md)
and independent [Draco Box fixture](../Tests/MessEarthKitTests/Fixtures/DracoBox/PROVENANCE.md).
They cover placement, winding, attributes, materials, native admission and
subdivision. Independent RGBA samples and a separate nearest/bilinear sampler
check base-level texture preservation, coverage and explicit policy rejection.
Preparation/export/reopen and cancellation checks cover retained policy and
source identity.

Synthetic oversize-prefix checks prove rejection before native decoding; they
do not prove arbitrary oversize decoding or complete native memory isolation.
Optimized-copy checks do not establish identical coarser mip samples. Exact
nearest-sampling ties are sensitive to Float UV precision. Processing beyond the
supported native working set or exact shared-mip/normal-field delivery requires
additional decoder or artifact contracts.
