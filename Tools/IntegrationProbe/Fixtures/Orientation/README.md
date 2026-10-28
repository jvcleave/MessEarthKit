# Original orientation / placement fixture

Authored for this repository with `Tools/Fixtures/generate-orientation-fixture.py`.
There is no third-party imagery or captured Google data in this fixture.

One GLB contains a 4 m square ground plane and a 2 m square, 0.8 m high box.
Both use interleaved position/normal/UV attributes and unsigned-short indices.
A parent node translates the model by (1, 0.5, -1) meters. Its embedded 2×2 PNG
has red NW, green NE, blue SW, and yellow SE quadrants on the ground plane.
Materials are explicitly unlit; the image sampler is nearest and clamped.

The tileset is anchored at WGS84 latitude 0°, longitude 0°, ellipsoid height 0 m
(ECEF 6378137, 0, 0). Its root maps local East/North/Up into ECEF and uses
REPLACE refinement with a coarse parent GLB. The first child translates by
(-5, 0, 0) in East/North/Up meters. The second translates by (5, 2, 0) and
references an external tileset whose root adds 1 m Up.

The complete leaf result has two ground planes and two boxes: **4 meshes,
56 vertices, 28 triangles**, with local East/Up/South bounds
**minimum (-4, 0.5, -7), maximum (10, 2.3, -1)**. Including the coarse parent,
applying the external transform twice, omitting a node translation, losing
Earth-coordinate precision, or using the wrong glTF/3D Tiles axis conversion
changes these independently specified results.
