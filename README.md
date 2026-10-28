# MessEarthKit

A standalone Swift package and macOS example app for preparing textured
geographic 3D assets. It supports native GLB/Draco decoding, local 3D Tiles
assembly, bounded Google Photorealistic 3D Tiles capture, source-folder save/reopen,
immutable CPU assets, and a Metal preview. The final MessScene GLB/USDZ delivery
format remains deferred. A real **200 × 200 m, 4 m detail** capture at 613 Race St,
Cincinnati has been decoded, saved, and reopened with matching geometry:
**152 meshes, 184737 triangles, 8.2 MB** of retained source files. GUI interaction
and visual inspection remain manual checks.

## Run the example

Open `MessEarthKit/MessEarthKit.xcodeproj`, select **MessEarthKitExample / My Mac**,
and Run. The existing project links the root Swift package; the app module is
named `MessEarthKitExample` to distinguish it from the library module.

For live captures, complete [Google Maps API key setup](#google-maps-api-key-setup)
first. The bundled reference and local-file imports work without a Google key.

For a geographic capture:

1. Enter an address and click **Resolve Address**, or enter coordinates directly.
   The example defaults to **613 Race St, Cincinnati, Ohio**. Address lookup uses
   the app's MapKit service and does not need the Google key. A direct lookup
   returned one match at latitude `39.1026327`, longitude `-84.515172`.
2. Set region width/depth in meters and the maximum geometric error in meters.
   Defaults are **200 × 200 m**, with **4 m** error. Lower error requests more
   detail. Whole intersecting tiles are retained, so actual bounds may be larger.
   **Maximum Requests** accepts a positive whole number and defaults to **512**
   per attempt. It counts root/child JSON metadata and GLB downloads; progress
   shows requests used against this budget. Raise it to allow more source
   requests while retaining the separate byte, traversal, and geometry limits.
3. Enter your Google Maps Tile API key in the secure field and click
   **Capture Region**. Map Tiles must be enabled for your key's project. Optional
   automatic loading from a local login-Keychain item is described in
   [key setup](#google-maps-api-key-setup). Manual field edits take precedence over
   a pending credential load. Keys are absent from preferences, source files,
   saved captures, and diagnostics.
4. Preview, then click **Save Capture…** and choose a new folder. Captures store
   their original GLB payloads plus a local `tileset.json` with placement data.
   Reopen it through **Open Tileset Folder…** without needing a key or network.

Each capture attempt also checkpoints completed tiles to a new folder under the
app's Application Support directory, at `MessEarthKit/Recoveries`. If a request
limit or another error interrupts capture, the app tries to preview those tiles
with an explicit **Partial capture** warning and the interruption reason. This
does not claim coverage of the full requested region. **Open Last Download**
reopens the most recent checkpoint offline, including after restarting the app;
**Show Downloads** reveals its files in Finder. Cancellation retains the same
checkpoint for later opening. Raw files remain available even when decoding
cannot prepare a preview within its limits.

Recovery folders are retained until the user removes them. Recovery reopens
completed downloads; it does not resume the interrupted traversal. Captures made
before checkpoint support was added cannot be recovered from memory after an
error. Saving a partial capture preserves its incomplete status when reopened.

The capture controls show a **$0.006 USD standard-rate estimate per attempt**,
based on one new Google root session. This may be $0 while the billing account's
shared **1000/month free allowance** remains; the app cannot read that balance.
Additional tiles do not multiply the session charge. A session may count even if
the capture later fails or is cancelled; opening/saving local captures uses no
Google session. This is the global list rate before taxes and account discounts,
checked **October 28, 2026**, with an in-app link to
[Google pricing](https://developers.google.com/maps/billing-and-pricing/pricing).
Google describes the billing unit in its
[Photorealistic 3D Tiles GA announcement](https://mapsplatform.google.com/resources/blog/build-immersive-maps-at-scale-with-photorealistic-3d-2d-and-street-view-tiles-now-in-ga/).

Local workflows remain available:

- **Load Reference** opens the bundled two-tile scene with color-coded ground
  planes and simple buildings. Red/green are the northern corners, blue/yellow
  the southern corners.
- **Open GLB…** opens a self-contained static binary glTF file.
- **Open Tileset Folder…** authorizes a directory containing `tileset.json` and
  its referenced local GLBs/JSON files. The whole directory is authorized so
  sibling files remain accessible inside the app sandbox.
- Drag to orbit, scroll to zoom, and use **Reset View** to frame the model.
- Saving a standalone GLB retains its original filename inside the chosen folder;
  reopen that file through **Open GLB…**.

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
   your network changes. This follows Google's [web-service key restriction guidance](https://developers.google.com/maps/api-security-best-practices).
6. Open Google Maps Platform's **Quotas**, select Map Tiles API, and review the
   Photorealistic 3D Tiles daily root-tileset quota. Set a project limit appropriate
   for your usage. Google's [quota instructions](https://developers.google.com/maps/documentation/tile/usage-and-billing)
   describe how to change it. This project-level quota is separate from the app's
   **Maximum Requests**, which counts metadata and GLB requests within one capture.
7. Run **MessEarthKitExample**, enter the key string in its secure field, resolve
   an address, and click **Capture Region**. A newly enabled API can take a few
   minutes to become available. The field takes the
   key string, not its Cloud resource ID or display name.

Manual entry keeps the key in memory for the current app session. The example
does not currently save newly entered keys. Optional automatic loading reads a
generic-password item from the login Keychain with service
`com.jvclabs.MessEarthKit.MapTiles` and account `default`; its password is the key
string. Provisioning this item is separate from creating the Cloud key, and the
signed app must have permission to read it. Restart the app after provisioning.
The service name identifies the example app's local credential and is independent
of your Google Cloud project ID. The key stays out of repository files and saved
captures.

Common setup issues:

| Symptom | What to check |
| --- | --- |
| Google rejects the key | Confirm billing, API enablement, API restrictions, and the allowed public IP addresses in the same project as the key. |
| HTTP 429 | Check the project's root-request quota and service rate limits. Changing region/detail does not reset them. |
| Source request count exceeded | Increase the app's Maximum Requests or reduce the capture area; this is a local per-attempt budget. |
| Key field is empty after relaunch | Re-enter a session-only key, or check the optional Keychain item's service, account, and app access. |

## Package use

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

```swift
let center = try EarthGeographicOrigin(latitude: 39.1026327, longitude: -84.515172)
let request = try EarthCaptureRequest(
    center: center, widthMeters: 200, depthMeters: 200,
    maximumSourceRequests: 1024
)
let session = EarthCaptureSession(apiKey: suppliedKey)
let capture = try await session.capture(request: request) { progress in
    // Deliver throttled presentation updates to the host's UI actor.
}
let rootFile = try await EarthCaptureStore().save(capture: capture, directoryURL: newFolderURL)
```

For durable recovery, pass `recoveryDirectoryURL: newRecoveryFolderURL` to
`capture`. The parent must exist and the recovery folder must be new. Each
selected GLB is written before an atomic `tileset.json` checkpoint is published.
The library still throws the original capture error; import that manifest to
prepare the completed tiles offline. `capture.incompleteReason` identifies an
unfinished snapshot and survives ordinary source-folder save/reopen. The marker
is cleared only after traversal and decoding succeed. The host owns directory
authorization and retention; checkpoints contain local references, without the
service key or session URLs.

One importer is a serial actor. Each explicit request returns a result, throws a
typed `EarthImportError`, or throws `CancellationError`. Native decoder objects
do not escape the worker. Cancellation is cooperative: an active native decode
finishes before the next cancellation check, while Swift traversal/vertex loops
also check cancellation. The caller keeps source files accessible and unchanged
for the duration of the import.

## Current supported subset

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
  Remote capture culls the opposite hemisphere, intersects the requested region,
  and descends until the selected
  geometric-error target is met. Unavailable detail and exhausted budgets fail
  explicitly. Opt-in disk recovery and the example's partial preview retain an
  incomplete marker rather than claiming a complete capture.
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
bytes. Those limits are capture settings, separate from the eventual consumer's
limits; they are not a claim about total process/GPU memory. Local tile references
must remain within the selected directory, including after resolving symlinks.

Capture requests are serial and cancellable. `maximumSourceRequests` sets the
positive per-attempt request budget (default 512), including metadata and GLBs;
cached resource reuse does not consume another request. Other limits remain
256 selected tile placements, 64 hierarchy levels, 16 MiB per response, and the
configured node/total-byte budgets. Requests stay on Google's HTTPS 3D Tiles
endpoint; redirects are refused. The ephemeral transport has no persistent cache
and reports status errors without credential-bearing URLs. Rewritten local
manifests retain selected transforms and bounds while removing service URLs,
keys, and sessions. Saving creates a new folder and removes its own incomplete
save output after failure/cancellation; existing destinations are never replaced.
Recovery checkpoints have separate retention: completed downloads survive both
failure and cancellation without increasing request or import limits.

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
session propagation, resource budgets, save/reload, and cancellation. Sixteen
tests include parameterized completion, default/custom request exhaustion,
completion above 512 requests, cancellation, invalid request budgets, and
decoder-limit cases that verify durable checkpoints, explicit incomplete status,
and existing-folder protection. The original
orientation fixture is shared by the probe,
tests, and app; its independently specified coordinate/texture contract and
authoring script are documented in
[`Tools/IntegrationProbe/Fixtures/Orientation/README.md`](Tools/IntegrationProbe/Fixtures/Orientation/README.md).
The independent compressed fixture and its CC-BY-4.0 attribution are documented in
[`Tests/MessEarthKitTests/Fixtures/DracoBox/PROVENANCE.md`](Tests/MessEarthKitTests/Fixtures/DracoBox/PROVENANCE.md).

See the [initial plan](docs/internal/plans/MESS_EARTH_KIT_INITIAL_PLAN.md),
[current handoff](docs/internal/handoffs/mess-earth-kit.md), and retained
[USGS alternative notes](docs/internal/research/USGS_BUILDING_RECONSTRUCTION_ALTERNATIVE.md).
