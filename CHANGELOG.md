# Changelog

## Unreleased

- Add optional `.glb.info.json` delivery with statistics, export settings,
  attribution, size/SHA-256 matching and a bounded PNG from the example app.
- Include selected GLB contents in app export filenames using `geom`, `norm`,
  `vcol`, `uv`, `mat` and `tex` tags.

## 1.0.0 — 2026-10-29

Initial 1.0 release of the MessEarthKit Swift package and macOS example app.

### Swift package

- Download Google Photorealistic 3D Tiles into resumable, disk-backed capture
  archives with retained source files and request tracking.
- Prepare large captures offline as aligned model parts in a paged catalog.
- Read local `tileset.json` hierarchies and self-contained GLBs, including native
  Draco decoding, into immutable CPU geometry and material/image values.
- Export combined GLBs with Full, Untextured and Minimal presets, or individual
  choices for normals, vertex colors, UVs, materials and texture images.
- Preserve shared geographic placement, capture identity and attribution through
  preparation and export; keep original downloaded assets intact.
- Generate flat normals when missing, retain precision through geographic
  transforms, and report omitted zero-area source triangles.

### macOS example app

- Automatically save projects with named locations, editable capture areas and
  independently registered detail variants.
- Download, pause and resume a selected variant; prepare completed captures
  offline while retaining earlier source attempts.
- Preview entire regions or individual parts in Textured, Solid and Wireframe
  modes with explicit GPU-memory admission checks.
- Export from each variant with progress, cancellation, persistent history and
  Finder actions.
- Support city lookup on macOS 15.6 through Core Location and on macOS 26+ through
  MapKit; preserve manually edited names.

### Integration

- Requires macOS 15.6+ and Swift 6.2+; build the example app with Xcode 26+.
- Add the `MessEarthKit` library product through SwiftPM using version `1.0.0`.
- Captured files can be read through `EarthCaptureImporter`; prepared catalogs
  use `EarthPreparedCollection`. Both return CPU assets through the public library.
- Exported GLBs can be consumed by compatible glTF 2.0 apps without EarthKit.
  The consuming app owns file authorization, GPU resources and rendering.

### Supported scope

The importer supports the documented static triangle, material and 3D Tiles
subset. Animation/skinning, implicit tiling, extra material maps and unverified
extensions remain unsupported. Preparation/import budgets and actual hardware
capacity still apply. USDZ export is not included.

See the [README](README.md) for the app workflow and SwiftPM examples, and the
[technical reference](docs/TECHNICAL_REFERENCE.md) for format contracts and limits.
