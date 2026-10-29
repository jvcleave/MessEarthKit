# Native decoder boundary, geometry and texture subdivision

Updated: 2026-10-28. Stage 3B1 and base-level texture subdivision (3B2A) are
implemented. Stage 3B2B adds opt-in portable optimized copies with regenerated
crop mipmaps and approximate normals. Exact crop-boundary mip/normal reproduction
and arbitrary native-source decoding remain outside the portable contract.

## Implemented boundary

`EarthDracoAdmission.mm` reads the pinned Draco topology prefix with a constant-
memory cursor before native mesh decoding. It checks signature/version/method,
bounded metadata, encoded counts and a conservative final point bound. It never
allocates a mesh or count-sized vector. Swift invokes this before GLTFKit2 asset
loading; the plugin invokes the same guard before `DecodeMeshFromBuffer`.
Both run a 2M point/face admission ceiling. Post-decode checks remain as well.

Sequential encoding supplies its encoded point and face counts. Edgebreaker can
create point duplicates at attribute seams, so admission uses three corners per
face plus legacy added vertices rather than trusting the glTF POSITION accessor.
This can reject inputs whose final merged point count would fit. Metadata is
limited to 32 nesting levels and 4,096 total entries/nodes; unsupported/malformed
source structure is explicit. The original raw payload remains available.

This is topology admission, **not** a complete bound on Draco's internal
allocations, a sandbox or crash isolation. Attribute/entropy decoding still uses
the native library. Destination budgets and header declarations alone cannot
promise arbitrary native decoding. No native ceiling was raised in this stage.

## Geometry subdivision

`EarthGeometrySubdivision` decodes only a supported source working set: 128 MiB
source GLB, 2M prepared source vertices (including flat-normal expansion), 6M
source indices, bounded metadata and admitted native topology. The existing
worker owns the native objects/CPU arrays; no aggregate capture is decoded.

The destination's per-model vertex/index budgets govern triangle partitioning.
Each part remaps referenced vertices and retains ordered triangle winding,
normals, colors, material factors/alpha/unlit/sidedness, UVs and texture sampling.
Node transforms, reflected winding and UV transforms are baked exactly once by
the source decoder. Original tile transforms stay in the local tileset. Texture
bytes stay original when no texture split is required; oversized admitted textures
use the lossless crop path below. The internal derivative writer does not
choose the standalone codec. Combined standalone delivery now uses GLB; USDZ is
optional future work.

Derived assets carry their original source-payload identifier, remain outside
the immutable raw archive, and are journaled/reused for repeated placements.
They enter the existing incremental model writer/catalog and selected exporter.
If even one triangle plus its material/texture cannot fit a destination, an
explicit preparation error preserves originals and completed output. Resolution
is not lowered to make a texture fit.

## Base-level texture subdivision

`EarthTextureRaster` reads supported ImageIO samples at the offline file-I/O
boundary; no Core Image or per-frame imaging was introduced. It admits up to
16,384 pixels per edge and 256 MiB decoded RGBA, requires 8-bit RGB/grayscale,
and avoids drawing through a premultiplied or color-converting context. An alpha
representation requiring lossy unpremultiplication is rejected. Output uses
lossless PNG, preserving decoded RGB/straight-alpha samples without resizing.
The source decoder, raster and output crops belong to one worker; these figures
are source admission budgets, not a total process-memory promise.

`EarthTextureSubdivision` clips triangles in baked UV space using barycentric
coordinates. Repeat, mirror and clamp intervals are affine independently on each
axis; pixel gutters use the original wrapped neighbors. Nearest-only crops need
no gutter, while bilinear crops use one pixel on each side. Crops use clamp and
remapped UVs; the authored wrap behavior is represented in the clipped geometry
and crop pixels. This follows the source sampling coordinate/wrap contract in
the [glTF texture specification](https://github.com/KhronosGroup/glTF/blob/main/specification/2.0/Specification.adoc#textures).
Each crop must meet destination dimension/RGBA budgets; clipped geometry still
passes through destination vertex/index/source-byte packing. Cache size is 16 MiB
of encoded crops. Per-triangle interval work is bounded (4,096 periods per axis,
65,536 axis intervals and 65,536 Cartesian candidate regions). Excess work is an
explicit retained-source failure rather than silent truncation.

**Preserve appearance** rejects mipmapped subdivision: regenerating independent
crop mip chains changes cross-region filtering, and the PNG contract cannot store
the needed shared levels. It also rejects lit varying-normal clips that change
normalized normal interpolation; unlit or constant-normal lit triangles support
exact base-level clipping.

**Optimized copy**, selected explicitly before preparation, retains the requested
mipmap filter and lets the existing renderer generate each cropped PNG's mipmaps.
It does not disable mipmapping or resize the base image. New clipped normals use
normalized barycentric interpolation. At a zero interpolant, the geometric face
normal provides a valid approximation; a degenerate unusable surface still fails.
Seams, distant filtering and smooth lighting may differ. This is a portable GLB
choice, not exact reproduction of original filtering. Profile v2 stores the
permission in derivatives, model manifests and combined assets; v1 remains exact.
Imported immutable captures/collections expose it for host notices. The permission
does not assert that every prepared model was changed.

Unsupported 16-bit/pixel layouts and insufficient room for gutters remain explicit
in either mode. Nearest ties at exact texel edges
are sensitive to Float UV precision; tests cover near-edge samples while
excluding exact discontinuous nearest ties within 1e-6 source texel.

## Verification and its limits

The authored orientation fixture and the independent Draco Box exercise normal
and compressed subdivision. Every ordered triangle's position/normal/UV/color
and material/texture settings are compared after placed-model import. Variants
include a reflected/non-uniform node transform, UV offset/scale/rotation,
alpha/material changes and generated flat normals. The fixture's independent
14 triangles per placement and local bound anchor the placement check. Sparse
subset export and cancellation between parts use the same source resources.

Native admission uses a genuine valid Draco payload against small test budgets,
empty metadata insertion, truncation and malformed metadata. A synthetic >2M
point topology prefix inside a glTF wrapper with small accessor declarations
proves that admission rejects before the native asset parser. This does not claim
successful processing of a genuine >2M-point encoded mesh or memory isolation.
No large committed fixture or bespoke verification executable was introduced.

The texture gate uses independent 6×4 RGBA samples with varying alpha and a
separate linear-light nearest/bilinear sampler. Seven filter/wrap cases compare
source and derivative samples, triangle area/winding, interpolated colors,
material settings and destination budgets; constant UVs do not duplicate geometry.
Offline full preparation/export/reopen and cancellation are covered. Strict mip/
normal rejection and optimized cases share the independent base-pixel, material,
coverage and color checker. The optimized checks add an authored affine normal
field, a singular opposed-normal fallback, retained minification filtering, policy
round-trips through folders/combined GLB, v1 compatibility and unchanged raw bytes.
These tests do not claim identical coarser mip samples. Gutter, 16-bit and repeat-
work failures remain explicit in either mode. Auth parsing separately tests bounded reason mapping,
credential absence and HTTP status propagation; no live source request is needed.

## Pinned upstream implementation checked

The 1.5.7 implementation supports the prefix layout used by the admission reader:
[sequential topology](https://github.com/google/draco/blob/1.5.7/src/draco/compression/mesh/mesh_sequential_decoder.cc),
[Edgebreaker topology](https://github.com/google/draco/blob/1.5.7/src/draco/compression/mesh/mesh_edgebreaker_decoder_impl.cc),
[Edgebreaker initialization](https://github.com/google/draco/blob/1.5.7/src/draco/compression/mesh/mesh_edgebreaker_decoder.cc),
[metadata encoding](https://github.com/google/draco/blob/1.5.7/src/draco/metadata/metadata_decoder.cc), and
[decode order](https://github.com/google/draco/blob/1.5.7/src/draco/compression/point_cloud/point_cloud_decoder.cc).
The API returns whole decoded meshes rather than independently consumable
triangle batches. These sources justify the conservative prefix guard and the
remaining allocation/isolation work; they do not prove a complete memory bound.

## Next bounded work

- The chosen portable route now permits approximation explicitly. Exact shared-
  mip/normal-field delivery needs a richer renderer/artifact contract and remains
  optional future work; it is not silently substituted into optimized GLB.
- Prototype an internally resource-bounded decoder or isolated helper before
  enabling sources beyond the supported native working set. Test genuine encoded
  oversize, resource failure and cancellation without taking down the host.
- Keep originals immutable and distinguish prepared subset/full coverage. Reuse
  the existing file-backed catalog/writer for texture/geometry derivative units.
