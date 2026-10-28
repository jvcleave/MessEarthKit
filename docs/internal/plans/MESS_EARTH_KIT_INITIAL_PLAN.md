# MessEarthKit Initial Plan

Status: capture workflow verified with controlled responses and a complete real
Google capture/save/reopen. GUI visual validation and consumer delivery remain pending.
Updated: 2026-10-28 (America/New_York).
Owning repository: `/Users/Shared/WORK_IN_PROGRESS/MAC_APPS/MESS/MessEarthKit`.

## Objective and definition of done

Build a standalone macOS capture application backed by a reusable Swift package,
following CMResearchKit's package/example-app ownership model. A user selects a
bounded geographic area and detail target, prepares textured geometry, previews
the result, and saves assets that can be imported into MessScene with correct
textures, orientation, and scale. The consumer format is deliberately deferred:
native GLB import and USDZ export are both candidates. Capture must not depend on
that choice or require MessScene to depend on MessEarthKit.

The first source is Google's Photorealistic 3D Tiles API. Source-policy review is
outside this plan at the user's direction and is being handled separately.

## Potential alternative route

Retain the [USGS-to-3D buildings notes](../research/USGS_BUILDING_RECONSTRUCTION_ALTERNATIVE.md)
for later evaluation: reconstruct terrain and buildings from USGS 3DEP lidar/DEM,
FEMA or local building footprints, and NAIP aerial imagery. The notes cover roof
reconstruction, aerial textures, procedural walls, candidate processing tools,
and a neighborhood-scale prototype.

This is a saved research alternative, not an adopted source implementation or a
change to the current capture milestone. Its source/tool claims remain to be
evaluated if selected, and its export suggestions do not settle GLB versus USDZ.

## Current source findings

- The root Swift package has private pinned GLTFKit2 0.5.15 and DracoSwift 1.5.7
  adapters, immutable CPU assets, local GLB/tileset import, bounded region/detail
  capture, and source-folder save/reopen. Sixteen focused tests use the original
  shared fixture, an independent compressed Khronos/Cesium fixture, and controlled
  source responses. The integration probe remains a separate non-UI client.
- The existing Xcode project now links that package and has a shared
  `MessEarthKitExample` app scheme plus app-owned Metal preview and file controls.
  App/project deployment targets are 15.6. The package uses Swift 6 language
  mode; the example keeps Swift 5 mode and explicitly isolates UI state while
  resource preparation remains off the main actor. Network-client and user-selected
  read/write entitlements support capture and saving. The app has address lookup,
  key/region/detail controls, preview, cancellation, and save/reveal actions.
  An app-owned estimate beside Capture Region shows the dated global list rate
  of $0.006 per attempt and the shared 1000/month free allowance, without claiming
  to know remaining allowance or actual billing totals.
  Maximum Requests now sets a positive per-attempt source-request budget, default
  512; progress shows used/allowed requests. The package's immutable request
  carries that budget through traversal and into recovery metadata.
- Capture checkpoints now preserve each completed selected tile in an app-owned
  recovery folder. Interrupted captures can preview and reopen offline with an
  explicit incomplete reason; cancellation and decode failure retain raw files
  too. Completion clears the marker only after successful traversal and decode.
  The app discovers the latest download after restart and provides open/reveal
  controls. The original failed in-memory attempt has no retained files to recover.
  Import and other capture limits remain independent; traversal resume is deferred.
- The supplied target address, 613 Race St, Cincinnati, Ohio, resolved to one
  MapKit result at 39.1026327, -84.515172. It is prefilled in the app's address
  field; coordinates can also be entered directly. The user authorized using
  `jvclabs-migration-2026` to provision a restricted development key. Map Tiles is
  enabled, the key is in the example's dedicated login-Keychain item, and a real
  authenticated root request succeeded. The root daily quota is capped at 100,
  raised from 10 with explicit user authorization after quota-triggered HTTP 429s.
- Google's required `3DTILES_content_gltf` declaration is now accepted by both
  local and network readers. The false detail error came from selecting tiles
  on the opposite side of Earth; region selection now culls those bounds.
  The real source also omits optional texture-filter settings, now handled with
  explicit client defaults. A **200 x 200 m / 4 m** capture at the supplied address
  saves and reopens successfully: **112 GLBs, 152 meshes, 184737 triangles,
  554211 prepared vertices, and 8202022 retained source bytes**. The source uses
  `KHR_materials_unlit`; compressed compatibility is covered independently.
- CMResearchKit has one public library module, immutable Sendable API values,
  explicitly isolated engines, and a nested example app that uses public APIs.
  The example owns presentation, file locations, scheduling, and Metal preview.
- MessScene already imports USDZ textured models and PLY point clouds. Its current
  USDZ reader uses meters, a right-handed Y-up frame, and explicit texture/UV
  conventions. Direct GLB import would require a new consumer import path;
  compatibility must be verified against the selected real consumer.
- Current MessUSDZImportKit limits include a 64 MiB source file, 4096 nodes,
  100,000 vertices per mesh, 600,000 indices per mesh part, 4096-pixel textures,
  and 256 MiB of decoded geometry/texture data. These are consumer limits, not
  universal USDZ or GLB limits. Apply them if the USDZ route is selected rather
  than imposing that format's current reader limits on every capture.

## Ownership and repository shape

```text
Package.swift
Sources/MessEarthKit/
    API/                 Requests, results, progress, errors, CPU asset values
    Tiles/               Source requests, tileset traversal, selection, decoding
    Geometry/            Geographic transforms and local mesh preparation
    Export/              Optional format conversion after the delivery decision
Sources/EarthDracoBridge/ Private native codec bridge
Tests/MessEarthKitTests/  Focused network-free contract tests
Tools/IntegrationProbe/  Small programmatic capture/decode client
MessEarthKit/            Existing Xcode example app and project
    MessEarthKit/
        Presentation/    SwiftUI views and main-actor observable view models
        Services/        Credentials, file access, job/persistence ownership
        Rendering/       App-owned preview renderer and resource lifetimes
docs/internal/           Plan and task handoff
```

Start with one importable library module, `MessEarthKit`. Add an integration
probe when needed to exercise the vertical slice. Do not split into multiple
public modules or introduce a general provider framework before a second actual
consumer/source establishes the need.

The package owns source access, tile selection/decoding, immutable CPU mesh and
texture values, geographic conversion, validation, and any selected export path. It must
run without SwiftUI, the example app, MessScene, MESS, or sibling checkout paths.
Codec/native implementation details remain private.

The example app is a public-API client. Its composition root creates services;
views send semantic actions to observable view models. App services own credential
storage, user-selected destinations, security-scoped access, persistence policy,
and job lifetime. Rendering resources stay out of broad Observation state.

Proposed API responsibilities, with names finalized during implementation:

- `EarthCaptureRequest`: geographic region, detail target, and resource budgets.
- `EarthCaptureSession`: explicitly isolated capture work with cancellation.
  An optional new recovery directory retains completed tiles and an atomic local
  manifest while preserving the original error/cancellation contract.
- `EarthCapture`: immutable CPU assets, local frame, actual selected bounds,
  counts, original source bytes, and source metadata. Unsupported or incomplete
  requests throw instead of returning an apparently complete partial capture.
  Reopened checkpoints expose `incompleteReason`, preserved through saving.
- `EarthCaptureProgress` / `EarthCaptureError`: typed progress and actionable
  failures, without client UI state or credential-bearing URLs.
- Format-specific exporter APIs are deferred until the consumer format is chosen;
  capture results remain independent of serialization and export APIs.

Use `async throws` and a typed progress boundary. Each explicit job completes,
fails, or cancels exactly once. Bound network concurrency and decoding/memory
work; cancellation releases owned temporary resources. Do expensive work off the
main actor, independently of the starter app's default actor setting. Do not add
a process-wide singleton or require runtime Python, Blender, or developer tools.

## Capture and output contract

1. Begin with a center coordinate and bounded dimensions in meters. The example's
   app-owned address lookup supplies coordinates without adding MapKit to the
   package; direct coordinate entry remains available.
2. Select tiles by geographic intersection and geometric error/detail. Respect
   nested transforms and refinement rules so parent/child content is not
   accidentally duplicated or omitted. Define coverage and limit outcomes
   explicitly. First captures may include whole intersecting tiles; exact polygon
   clipping is deferred, and actual output bounds are reported.
3. Inspect representative payloads before choosing a GLB decoder. Prove the
   extensions/compression they actually require, including Draco if encountered.
   Preserve mesh attributes, texture sampling, and source metadata; unsupported
   required features produce explicit diagnostics.
4. Keep geographic calculations and the origin subtraction in double precision.
   Convert to a nearby local frame in meters: East = +X, Up = +Y, North = -Z.
   Preserve origin/height-reference information as metadata; keep large Earth
   coordinates out of final float vertex positions. Apply transform, normal,
   winding, and UV conversions once at their owning boundaries.
5. Preserve source texture appearance through the decoded material representation.
   Verify UV orientation with asymmetric reference imagery and verify whether
   source materials are lit or unlit. Do not assume that mapping every source
   texture to a default lit base color preserves its appearance.
6. Preserve original GLB tile payloads and the hierarchy/transforms/metadata needed
   to assemble them. A region may span many GLBs, and an individual tile is not a
   complete region export. Reloading the source capture must retain placement and
   texture references. Do not commit to a custom consumer archive to preserve
   these working artifacts.
7. Preflight file, mesh, texture, and decoded-memory budgets for the target
   consumer once selected, alongside capture's own resource budgets. Split meshes
   where necessary; report an oversized region rather than silently exporting
   incomplete coverage. Do not raise consumer limits as a shortcut. Automatic
   decimation/texture atlasing requires a measured need.

### Consumer format decision: deferred

- Native GLB could avoid USDZ conversion and preserve the source's glTF material
  representation. MessScene would need an appropriate GLB import adapter, and
  multi-tile assembly/local-origin delivery must still be designed.
- USDZ could use MessScene's existing importer. It adds an export/material-mapping
  step and must satisfy that reader's limits. If selected, prove a native writer
  against the consumer, including USDZ archive alignment and texture semantics.
- Decide after the native capture/decode proof exposes actual payloads, material
  requirements, asset size, and implementation costs. Supporting both formats is
  not an initial requirement. Neither is selected as inherently better yet.

The eventual delivered asset must work independently of the running capture app.
Keep bounds, origin, detail, counts, and provenance available without exposing
credentials or transient session URLs. Final serialization and any optional
sidecar are part of the deferred delivery decision.

## Milestones

### 1. Native capture and decode proof

Local-fixture checkpoint: complete for the user-selected local-only pass. The
native probe produces 4 meshes, 56 vertices, 28 triangles, and the reference
bounds. Five focused tests, an actual-shader 2×2 Metal color/orientation check,
and the explicitly selected macOS app build passed. App resources and signatures
were inspected; the GUI was not launched after Xcode integration access was
declined. See [README](../../../README.md) for supported formats and how to run
the example. The original full milestone's real-source capture remains pending.

Capture-workflow checkpoint: Draco decoding now matches an independent
uncompressed reference within quantization tolerances. Eleven tests and the
affected app build pass. Controlled responses prove geographic selection,
refinement/session handling, bounded requests, cancellation, sanitized errors,
and independent save/reopen. The supplied address lookup and signed app
network/file permissions were checked. Actual Google coverage, source material
fidelity, and live compression variants still require an authenticated capture.

Establish the root package, concise repository guidance/README, and a small
programmatic client while preserving the starter app. Select and pin the minimum
decoder dependencies based on real payload and synthetic-asset evidence. Capture
one small region, preserve its native GLBs and placement data, and prepare local
textured CPU meshes independently of any final export format.

Done when a known-size/orientation synthetic tiled scene and one small real
capture decode and reload with correct tile placement, local bounds, scale, and
texture mappings. Inspect the prepared result through a minimal app-owned preview
or an independent reference viewer. Record material fidelity, native payload size,
vertex/triangle counts, peak memory, and unsupported content. An unresolved
material or coordinate defect is not a successful proof. USDZ writing and
MessScene GLB support are not prerequisites for this milestone.

This is the first bounded implementation milestone. Stop/checkpoint after it
before starting the next stage. Live-source checks require a user-supplied API
key; build the synthetic decode/placement proof independently if it is unavailable.

### 2. Reliable reusable capture engine

Current implementation provides bounded serial networking, region/error
selection, cancellation, typed errors, and original-source persistence. Its
controlled-response tests pass; real-source acceptance remains pending before
this milestone can be considered complete.

Complete explicit region/detail semantics, bounded traversal/download/decode,
resource preflight, deterministic output selection, typed progress/errors,
cancellation, and temporary-file cleanup. Retain only meaningful coverage for
coordinate conversion, refinement selection, material/export fidelity, and
operation lifetime. Ordinary tests do not contact the live API.

Done when another non-UI client can prepare, save, and reload a capture through the
public API, failures/cancellation are distinguishable, and budget exhaustion or
partial coverage cannot be mistaken for a complete capture.

### 3. macOS example application

The initial capture/preview/save workflow and app-owned address lookup are
implemented. The default target is the supplied Cincinnati address. A key is
entered in a secure field or loaded from the app's dedicated Keychain item.
Interactive map selection,
final export controls, and real capture acceptance remain later work.

Replace the starter screen with a focused workflow: credentials, location/region,
detail/budget controls, capture/cancel, prepared-result preview, and save/reveal.
Begin with coordinate entry; add place search/map selection after choosing the
required lookup/map integration. The preview consumes prepared package values;
it does not implement a second tile pipeline. Final export controls follow the
consumer format decision in milestone 4. Reopen saved captures through the same
package value boundary to prove that preparation is independent of source access.

Done when a user can capture, save, reopen, and preview without command-line tools,
presentation stays responsive, and file access/resource lifetimes are explicit.

### 4. Consumer format decision, acceptance, and distribution readiness

Choose the delivery format using evidence from native capture and preview. Add
the selected package exporter and/or consumer-owned importer in their smallest
owning repositories, without coupling capture to that format. Run a representative
delivered asset through MessScene's real import/render path.
Check textures, normals/material appearance, cardinal orientation, scale, camera
framing, responsiveness, and persistence after closing the capture app. Any
necessary consumer adaptation must be scoped separately in its owning repository.
Then document standalone setup and the chosen pinned dependency/native-artifact
distribution process; add release tooling only when distribution is requested.

Done when a fresh capture can be saved and imported by the user with the
capture app no longer running, and the repository builds without sibling paths.

## Verification and first decisions

- Documentation-only updates require diff review only. The implemented local
  checkpoint has already passed its focused package/probe/Metal/app checks;
  repeat them only for relevant subsequent changes.
- Implementation uses focused network-free tests for the distinct risks above,
  one opt-in live integration probe, and the affected macOS example-app build.
- If USDZ is selected, use MessUSDZImportKit's existing inspection tool as an
  external development check; do not introduce a sibling-path library dependency
  just to validate exports. Verify the selected format in MessScene at the
  consumer acceptance gate.
- SwiftPM output belongs under
  `${MESS_BUILD_CACHE_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds}/MessEarthKit/swiftpm`;
  ordinary Xcode builds use normal DerivedData.
- Resolve decoder/compression support, source material fidelity, and practical
  capture budgets in milestone 1. Resolve the consumer format and any required
  writer/importer compatibility later at milestone 4. Those
  are evidence-driven implementation choices, not assumed solved capabilities.
- Globe streaming inside MessScene, a custom consumer archive, multiple source
  backends, timeline features, and super-repository/submodule changes are outside
  this initial plan.

## Source references

Local paths below are relative to the MessEarthKit repository root.

- Local ownership model: `../CMResearchKit/AGENTS.md`,
  `../CMResearchKit/README.md`, `../CMResearchKit/Package.swift`, and
  `../CMResearchKit/CMResearchKit/CMResearchKit/Presentation/WorkspaceViewModel.swift`.
- Local consumer contract: `../MessUSDZImportKit/README.md`,
  `../MessUSDZImportKit/Sources/MessUSDZImportKit/USDZImporter.swift`, and
  `../MessSceneApp/MessSceneApp/README.md`.
- [Google custom 3D Tiles client requests and GLB content](https://developers.google.com/maps/documentation/tile/create-renderer).
- [Khronos glTF specification and extensions](https://registry.khronos.org/glTF/).
- [OpenUSD USDZ archive specification](https://openusd.org/release/spec_usdz.html).
- [Apple USD authoring guidance](https://developer.apple.com/documentation/usd/creating-usd-files-for-apple-devices).
