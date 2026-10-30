# Optional GLB information companion

The example app exports `<name>.glb` and `<name>.glb.info.json` into the same output
directory. The GLB is a standalone glTF asset. Consumers may use the companion for
library labels, statistics and a thumbnail without decoding geometry or uploading
textures. Copy both files to retain that information; copying only the GLB remains
valid.

## SDK export

`EarthGLBExporter.export(plan:fileURL:progress:)` keeps its existing GLB-only
behavior. Call `exportWithInfo(plan:fileURL:preview:progress:)` to publish an
information companion as well. `EarthGLBExportDelivery` reports the GLB URL,
optional info URL and any companion warning.

The exporter hashes the exact bytes while writing the GLB. It derives statistics
and bounds from the selected output, including the captured export options.
Sidecar generation does not change the GLB bytes. Existing destinations are never
overwritten. A thumbnail or companion failure cannot remove a published GLB;
the delivery reports a warning and the app still records its export history.

The optional `EarthGLBExportPreview` contains awaited, actor-neutral `consume`
and `finish` callbacks. `consume` receives the current decoded prepared part;
release it before returning. `finish` returns PNG data after all parts succeed.
Rendering and file authorization belong to the host, not the SDK. A failed part
omits the entire thumbnail rather than presenting an incomplete region.

The example app composites a 256-by-256 image using the same camera and appearance
controls as its preview renderer. It preserves depth/color between parts and
releases each part after GPU completion. Each upload is admitted against a
256 MiB part budget and the device working set. Exceeding that budget leaves
`thumbnail` null, retains the complete GLB and reports the preview warning.

## JSON schema 1

The file is UTF-8 JSON, at most 1 MiB. Every top-level key below is required.
Dates use ISO 8601 UTC. An unavailable thumbnail is an explicit JSON null.

| Field | Value |
| --- | --- |
| `schemaVersion` | Integer `1`. |
| `name` | Suggested display name, at most 4,096 UTF-8 bytes. |
| `exportedAt` | Export completion date. |
| `glb` | `fileName`, positive `byteCount`, and lowercase 64-character SHA-256 `sha256`. |
| `geometry` | Positive `vertexCount`, `triangleCount`, `meshCount`; nonnegative `materialCount`, `textureCount`; three-element finite `minimum` and `maximum` arrays. |
| `exportOptions` | Boolean `includeNormals`, `includeVertexColors`, `includeTextureCoordinates`, `includeMaterials`, `includeTextures`. Textures require UVs and materials. |
| `attributions` | Array of source attribution strings. |
| `thumbnail` | Null, or the image object described below. |

Bounds describe the exported vertices in local meters: East +X, Up +Y, North -Z.
Triangle and mesh counts describe the actual combined GLB; omitted materials and
textures have zero counts. The GLB itself retains capture identity and geographic
placement. Renaming a library label need not rewrite either source file.

A thumbnail object contains `mimeType: "image/png"`, integer `width` and `height`
between 1 and 512, and `data` containing base64-encoded PNG bytes without a data-URL
prefix. Decoded PNG data is at most 768 KiB, and its actual dimensions must match
the declared dimensions. There are no external image paths.

## Consumer behavior

Treat this as advisory metadata. Check `glb.byteCount` and `glb.sha256` against the
selected GLB before adopting its name or thumbnail. Compute the hash while reading
or copying the asset. `EarthGLBInfo.decode(_:)` checks the metadata structure;
the consumer still owns matching it to its chosen GLB and decoding PNG pixels.
The original `fileName` is descriptive: the size/hash binding survives renaming
or copying the unchanged asset.

Use the normal GLB import path when the companion is absent. Report an invalid,
unsupported or mismatched companion as a metadata warning while allowing a valid
GLB to import. Never use the companion to bypass geometry/material validation.
Store accepted information and thumbnails in the consumer's own library cache.

Sandboxed consumers can ask for both files together or authorize their containing
folder. Single-file authorization may not grant sibling-file access; it must not
be required to import the standalone GLB.
