> Reference status: potential alternative route, retained for later evaluation.
> User-provided notes below are preserved as supplied. They are not an adopted
> implementation plan; the project decision between GLB and USDZ remains deferred.

---

# USGS-to-3D Buildings: Recommended Pipeline

The idea is to use USGS elevation and lidar data, FEMA/USGS building footprints, and publicly available aerial photography to generate real-world 3D environments that can be exported as `.glb` and `.usdz`.

The key advantage is that you can create and distribute your own 3D assets without depending on Google's proprietary 3D meshes.

## 1. Proposed pipeline

User selects a geographic area

Address, coordinates, bounding box, or polygon

USGS 3DEP

Terrain + lidar

FEMA

Building outlines

USDA / USGS

Aerial imagery

3D Reconstruction Engine

Build terrain • Estimate roof shapes • Extrude walls • Add textures

Mesh and Texture Optimization

UV mapping • Materials • Polygon reduction

GLB

Web / 3D viewer

USDZ

Apple AR

## 2. Data sources and links

| Source              | What it contributes                                        | Official links                                                                                                          |
| ------------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| USGS 3DEP lidar     | 3D points for roofs, trees, and terrain                    | [Lidar Explorer](https://apps.nationalmap.gov/lidar-explorer/?utm_source=chatgpt.com)                                   |
| USGS 3DEP DEM       | Bare-earth terrain elevation                               | [National Map Downloader](https://apps.nationalmap.gov/downloader/?utm_source=chatgpt.com)                              |
| FEMA USA Structures | Building footprint polygons                                | [USA Structures](https://gis-fema.hub.arcgis.com/pages/usa-structures?utm_source=chatgpt.com)                           |
| USDA NAIP           | Aerial imagery for ground and roof textures                | [NAIP Imagery](https://naip-usdaonline.hub.arcgis.com/?utm_source=chatgpt.com)                                          |
| USGS NAIP Plus      | Additional high-resolution orthoimagery in supported areas | [Imagery service](https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPPlus/ImageServer?utm_source=chatgpt.com) |

USGS confirms that lidar point clouds capture buildings and vegetation, whereas standard DEMs represent bare-earth terrain. FEMA's USA Structures dataset was developed collaboratively with USGS and other federal agencies.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://www.usgs.gov\&sz=32)

U.S. Geological Survey+2



## 3. How to generate the buildings

The reconstruction process would work as follows:

1. Download 3DEP lidar in LAS/LAZ format for the selected geographic area.
2. Get building polygons from FEMA USA Structures or a better local municipal footprint dataset.
3. Match lidar points to footprints to isolate the likely roof points for each building.
4. Estimate building heights and roof geometry from the lidar, using the nearby ground elevation as the base.
5. Generate walls and roofs by creating closed 3D meshes.
6. Apply imagery and procedural materials, then merge buildings with the 3DEP terrain mesh.
7. Export GLB and USDZ, preserving real-world scale and optionally recording geographic coordinates in model metadata.

A significant technical caveat: 3DEP's baseline lidar classification does not guarantee that buildings are individually labeled. You'll often need custom segmentation, footprint matching, and roof-plane fitting. USGS has specifically investigated enhanced point-cloud classification.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://www.usgs.gov\&sz=32)

U.S. Geological Survey



## 4. Texture options

[What is Aerial Mapping? | West Coast Aerial Photography, Inc](https://images.openai.com/static-rsc-4/JeZRQuQkC2eaQmbPcRtqJEEs_fRdLX6LVnODwXsTzXjyvwVcteu0pwuhkijj0F4ZgapSRsfQ-hAGQhrtom0D_VsHSkA5nd2yS2o_8-MmQ8mXogjRbkGDPbj3kcxT_RCLlst77nEPAg7qmvAgByLcrf3T5lcQKtxkGcHBP_GM0SQ?purpose=inline)

A. Aerial orthophotos — terrain and rooftops

Use USDA NAIP or higher-resolution public orthophotos as image textures. These work well for roads, lawns, and roofs, but do not show vertical building façades.

[USDA NAIP catalog](https://catalog.data.gov/dataset/national-agriculture-imagery-program-naip-imagery?utm_source=chatgpt.com)

[Building (buildify) NYC - Download Free 3D model by abhayexe \[4467b3a\] - Sketchfab](https://images.openai.com/static-rsc-4/MoLrDnXoY2RIaJ6--hPI1uGHoIbtmiOMgiYn6iZw_ECgV3LGZ2y9fvskLASIdj5M6KP4F5T5bBMfcsKvT_JHEKoeRy5GDPCHyO4sO91K0fNpMAap3vHCxsEtst-yi0j4Hh-IV2NZtoI9z1AtJ3asZSBov4zG9s96U2F6nWcqMFE?purpose=inline)

B. Procedural materials — walls and roofs

Automatically assign brick, concrete, siding, glass, or roof materials using building attributes and heuristics. These are visual approximations rather than photographs of the actual façades.

[House 1920 - Buy Royalty Free 3D model by 3DA - Loïs PUIG (@3da.io) \[7331fe2\] - Sketchfab Store](https://images.openai.com/static-rsc-4/UUQNoql2njaTVnYVXGt1PFOjADk9Z-E2MSTOAXAUkI47yTm8kr4LOmzfzNO-U8evM9xry6o5UmTRpD_rD4w4Rzqczo0vAFU6f0_jOP4VjMs8Yo7RcCYMLOajQ9UiilMYNfJKzpodcReQm-BdmhHHTuaZ6ukvLPaFLeuzfvmlq1Q?purpose=inline)

C. Oblique aerial photography — realistic façades

Where licensed oblique images or existing photogrammetry are available, reconstruct true façade textures and more detailed geometry. This is the most promising route to Google Earth–like realism, but coverage and licensing are the main obstacles.

Recommended first version: Real aerial textures for terrain and rooftops, plus procedurally textured walls. This balances accuracy, cost, and automated generation.

## 5. Processing software

| Tool                    | Role                                               | Documentation                                                                                 |
| ----------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| PDAL                    | Read, filter, classify lidar                       | [PDAL](https://pdal.io/?utm_source=chatgpt.com)                                               |
| GDAL                    | Process DEMs and orthophotos                       | [GDAL](https://gdal.org/?utm_source=chatgpt.com)                                              |
| GeoPandas               | Process building footprint polygons                | [GeoPandas](https://geopandas.org/?utm_source=chatgpt.com)                                    |
| Open3D                  | Point cloud processing and mesh reconstruction     | [Open3D](https://www.open3d.org/docs/release/?utm_source=chatgpt.com)                         |
| Blender                 | Combine models, generate materials, export GLB/USD | [Blender pipeline](https://www.blender.org/features/pipeline/?utm_source=chatgpt.com)         |
| Apple Reality Converter | USDZ conversion and validation                     | [Apple AR tools](https://developer.apple.com/augmented-reality/tools/?utm_source=chatgpt.com) |

For a concrete starting point, [PDAL's 3DEP tutorial](https://pdal.io/en/stable/tutorial/iowa-entwine.html?utm_source=chatgpt.com) demonstrates reading USGS point-cloud data and generating an elevation model.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://pdal.io\&sz=32)

Point Data Abstraction Library (PDAL)



## 6. Expected quality and limitations

| Feature           | Expected result                                            |
| ----------------- | ---------------------------------------------------------- |
| Ground elevation  | High accuracy where quality lidar is available             |
| Building position | Good, subject to footprint accuracy                        |
| Building height   | Good when sufficient roof lidar points exist               |
| Roof shape        | Moderate to high depending on lidar density and complexity |
| Building walls    | Usually reconstructed rather than measured                 |
| Roof appearance   | Realistic from orthophotography                            |
| Façade appearance | Approximate unless additional imagery is available         |
| Windows and doors | Generally not recoverable from airborne lidar alone        |

The main challenge is building realism, not terrain accuracy. Better source imagery and more sophisticated roof reconstruction can improve results substantially, but no nationwide USGS pipeline automatically produces Google Earth–equivalent textured buildings.

## 7. Recommended MVP

Build a small prototype covering one neighborhood, perhaps a 500 × 500-meter area.

Start by downloading the 1-meter terrain DEM, source lidar, FEMA building footprints, and the best available public-domain aerial imagery. Align them in a local projected coordinate system, reconstruct simple roof forms, and generate buildings as separate meshes.

Export a GLB with terrain, buildings, and aerial textures first. Once geometry and materials are satisfactory, add USDZ conversion for Apple AR.

Keep the terrain and buildings separate internally so you can later substitute improved building geometry or façade imagery without rebuilding the entire scene.

### Key references

- [USGS — 3DEP Products and Services](https://www.usgs.gov/3d-elevation-program/about-3dep-products-services?utm_source=chatgpt.com)
- [USGS — Lidar vs. DEM](https://www.usgs.gov/faqs/what-difference-between-lidar-data-and-a-digital-elevation-model-dem?utm_source=chatgpt.com)
- [USGS — 3DEP Standards and Specifications](https://www.usgs.gov/3d-elevation-program-standards-and-specifications?utm_source=chatgpt.com)
- [FEMA — USA Structures Metadata](https://catalog.data.gov/dataset/usa-structures?utm_source=chatgpt.com)
- [USGS — NAIP Aerial Imagery](https://www.usgs.gov/centers/eros/science/usgs-eros-archive-aerial-photography-national-agriculture-imagery-program-naip?utm_source=chatgpt.com)

The central concept: Use USGS lidar for real 3D geometry, FEMA for identifying buildings, and NAIP imagery for visual appearance. Generate the finished assets yourself, making the GLB/USDZ files suitable for your own product or application, subject to checking the licensing of every incorporated source.