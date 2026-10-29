# MessEarthKit

Capture geographic 3D models from Google Photorealistic 3D Tiles, preview them on
your Mac, and export self-contained GLB files for other apps.

## Requirements

- **macOS 26 or newer** for the current app's location workflow, which uses
  MapKit city lookup when adding locations.
- **Xcode 26 or newer with Swift 6.2+** to build the app from source.
- An internet connection for map search, location naming and downloading tiles.
- For downloads, a Google Cloud project with billing enabled and a Map Tiles API
  key. Local preview and export of completed captures do not need a Google key.
- Available disk space for captures and exports, and enough GPU memory for the
  models you want to preview. Larger areas and finer detail need more resources.

To run from source, open `MessEarthKit/MessEarthKit.xcodeproj`, select
**MessEarthKitExample → My Mac**, and Run.

## Get a Google API key

1. Open the [Google Cloud Console](https://console.cloud.google.com/) and create
   or select a Cloud project.
2. Link an active billing account and enable **Map Tiles API** for that project.
3. Open [Credentials](https://console.cloud.google.com/apis/credentials), choose
   **Create credentials → API key**, and create a key dedicated to MessEarthKit.
4. Restrict the key to **Map Tiles API**. For this app's direct HTTPS requests,
   use an **IP addresses** application restriction with your public outbound
   IPv4/IPv6 addresses. Update these if your network or VPN changes.
5. Review the project's Map Tiles API quotas and usage-based charges before
   downloading.
6. In MessEarthKit, open **Settings** and paste the key. Choose **Save Key in
   Keychain** to keep it across launches; otherwise it stays in memory.

Google's [setup guide](https://developers.google.com/maps/documentation/tile/get-api-key),
[key restriction guidance](https://developers.google.com/maps/api-security-best-practices)
and [usage and billing guide](https://developers.google.com/maps/documentation/tile/usage-and-billing)
cover the current Cloud settings. API enablement can take a few minutes.

The Google Cloud project controls API access and billing. Projects inside
MessEarthKit organise your captures.

## Create a project

1. Open MessEarthKit and choose **New** in the Projects toolbar.
2. Give the project a name.
3. Open the project to work with its map, locations and capture variants.

Edits save automatically. Projects are stored under
`~/Documents/MessEarthKit/projects/`.

## Capture an area

1. Enter an address and choose **Update Map**, or pan and zoom to your area.
2. Choose **Add Location**. The new location uses the current map centre.
3. Keep its automatic city/coordinate name or enter your own name.
4. Set **Width (m)** and **Height (m)**. You can also move or resize the map box,
   or use **Draw Area** to draw a new rectangle. Choose **Done** when finished.
5. Choose **Add Variant**, then select that variant's **Detail**.
6. Choose **Download** on the variant card.

Adding a location or variant does not download Google tiles. **Download** starts
acquisition for that variant's saved area and detail. Use **Pause Download** and
**Resume Download** if needed. Completed downloads prepare models offline.

Add another variant to capture a different detail level. Detail locks once a
variant starts downloading. **Adjust Area** can update all pending variants
before any completes; afterward, use **Copy Location** for a different area.
Whole intersecting tiles can extend beyond the drawn rectangle.

## Preview

Choose **Preview** on a downloaded variant. If preparation is still running, it
continues before the model is displayed.

The **Display** menu offers:

| Mode | Appearance |
| --- | --- |
| **Wireframe (no textures)** | Triangle edges; the default. |
| **Solid (no textures)** | Neutral shaded surfaces. |
| **Textured** | Captured imagery and materials. |

For larger captures, switch from **Entire Region** to **Model Parts** and use
**Previous** / **Next** to view one part at a time. Solid and Wireframe skip
texture uploads. Preview still needs enough memory for the selected geometry.

Preview choices do not change downloaded files or export options.

## Export

1. Return to the project's variant cards and find the variant you want to export.
2. In its **Export** section, choose a preset or adjust the checkboxes.
3. Choose **Export GLB**. Preparation runs offline first if needed.
4. Choose **Show Export in Finder** beside the completed export.

| Preset | Included data |
| --- | --- |
| **Full** | Positions, triangle indices, normals, vertex colors, UVs, materials and texture images. |
| **Untextured** | The same vertex data and materials, without texture images. |
| **Minimal** | Positions and triangle indices. |

Normals, vertex colors, UV coordinates, materials and texture images can also be
selected individually. Enabling textures enables UVs and materials. Placement,
capture identity and attribution are always retained.

Exports are saved in the project's `output/<export UUID>/` folder. **Export
Again** creates another file and keeps earlier exports in the history. Export
does not require the whole capture to fit in Preview.

Export choices leave downloaded and prepared sources intact. Omitting images
from an export does not reduce the Google tiles already downloaded.

## Use the output in another app

| Output | What the consuming app needs |
| --- | --- |
| **Exported `.glb`** | A glTF 2.0 importer and renderer supporting static triangle meshes, node transforms and the included material, image and vertex attributes. No EarthKit dependency is required. |
| **Completed capture folder** | A compatible 3D Tiles reader for `tileset.json`, its referenced GLBs, geographic placement and transforms. EarthKit provides these APIs; source GLBs may require Draco decoding. Keep the folder's referenced files together. |
| **Ready prepared collection** | EarthKit's collection API to open the catalog and load its aligned model parts, or a compatible reader for its local `tileset.json`. Preserve the shared placement when combining parts. |

For GLB appearance, the consumer should handle embedded PNG/JPEG images, unlit
materials and vertex-color tinting when present. An export without normals needs
normals generated if the app uses lighting. Minimal exports need the consumer's
default surface appearance. See the [glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html).

Local importing and rendering do not need a Google key. Once converted to an
app's own geometry, materials and textures, normal rendering does not need the
GLB decoder. The app can retain the original file for reimport or Reset.

Preserve the capture's attribution when displaying it. A small GLB on disk can
still require substantial memory after decoding geometry and images.

Detailed contracts, existing Swift package examples and local verification
commands are in the [technical reference](docs/TECHNICAL_REFERENCE.md).
