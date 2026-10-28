"""Generate one original, spec-defined reference capture; no network or packages.

This is fixture authoring, not the decoder or an expected-output generator.
The accompanying README records the independently known dimensions/orientation.
"""

import json
import struct
import zlib
from pathlib import Path

destination = Path(__file__).resolve().parents[1] / "IntegrationProbe/Fixtures/Orientation"
destination.mkdir(parents=True, exist_ok=True)


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


pixels = bytes([0, 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 255, 255, 255, 255, 0, 255])
png = b"\x89PNG\r\n\x1a\n"
png += png_chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
png += png_chunk(b"IDAT", zlib.compress(pixels))
png += png_chunk(b"IEND", b"")

binary = bytearray()
views = []
accessors = []


def add_view(data, stride=None):
    while len(binary) % 4:
        binary.append(0)
    view = {"buffer": 0, "byteOffset": len(binary), "byteLength": len(data)}
    if stride is not None:
        view["byteStride"] = stride
    views.append(view)
    binary.extend(data)
    return len(views) - 1


def primitive(vertices, indices, material):
    vertex_view = add_view(b"".join(struct.pack("<8f", *vertex) for vertex in vertices), 32)
    index_view = add_view(struct.pack("<" + "H" * len(indices), *indices))
    first = len(accessors)
    positions = [vertex[:3] for vertex in vertices]
    accessors.extend([
        {"bufferView": vertex_view, "byteOffset": 0, "componentType": 5126, "count": len(vertices), "type": "VEC3",
         "min": [min(position[axis] for position in positions) for axis in range(3)],
         "max": [max(position[axis] for position in positions) for axis in range(3)]},
        {"bufferView": vertex_view, "byteOffset": 12, "componentType": 5126, "count": len(vertices), "type": "VEC3"},
        {"bufferView": vertex_view, "byteOffset": 24, "componentType": 5126, "count": len(vertices), "type": "VEC2"},
        {"bufferView": index_view, "componentType": 5123, "count": len(indices), "type": "SCALAR"},
    ])
    return {"attributes": {"POSITION": first, "NORMAL": first + 1, "TEXCOORD_0": first + 2},
            "indices": first + 3, "material": material, "mode": 4}


ground = primitive([
    (0, 0, 0, 0, 1, 0, 0, 1),
    (4, 0, 0, 0, 1, 0, 1, 1),
    (4, 0, -4, 0, 1, 0, 1, 0),
    (0, 0, -4, 0, 1, 0, 0, 0),
], [0, 1, 2, 0, 2, 3], 0)

building_vertices = []
building_indices = []
faces = [
    ((0, 1, 0), [(1, .8, -1), (3, .8, -1), (3, .8, -3), (1, .8, -3)]),
    ((0, -1, 0), [(1, 0, -3), (3, 0, -3), (3, 0, -1), (1, 0, -1)]),
    ((0, 0, 1), [(1, 0, -1), (3, 0, -1), (3, .8, -1), (1, .8, -1)]),
    ((0, 0, -1), [(3, 0, -3), (1, 0, -3), (1, .8, -3), (3, .8, -3)]),
    ((1, 0, 0), [(3, 0, -1), (3, 0, -3), (3, .8, -3), (3, .8, -1)]),
    ((-1, 0, 0), [(1, 0, -3), (1, 0, -1), (1, .8, -1), (1, .8, -3)]),
]
for normal, positions in faces:
    offset = len(building_vertices)
    for position, uv in zip(positions, [(0, 1), (1, 1), (1, 0), (0, 0)]):
        building_vertices.append((*position, *normal, *uv))
    building_indices.extend(offset + index for index in [0, 1, 2, 0, 2, 3])
building = primitive(building_vertices, building_indices, 1)
image_view = add_view(png)

gltf = {
    "asset": {"version": "2.0", "generator": "MessEarthKit original reference fixture", "copyright": "MessEarthKit reference fixture"},
    "extensionsUsed": ["KHR_materials_unlit"],
    "extensionsRequired": ["KHR_materials_unlit"],
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [{"name": "Reference Parent", "translation": [1, .5, -1], "children": [1]},
              {"name": "Reference Block", "mesh": 0}],
    "meshes": [{"primitives": [ground, building]}],
    "materials": [
        {"name": "Cardinal Texture", "extensions": {"KHR_materials_unlit": {}},
         "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0, "roughnessFactor": 1}},
        {"name": "Reference Building", "extensions": {"KHR_materials_unlit": {}},
         "pbrMetallicRoughness": {"baseColorFactor": [.65, .72, .8, 1], "metallicFactor": 0, "roughnessFactor": 1}},
    ],
    "textures": [{"source": 0, "sampler": 0}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33071, "wrapT": 33071}],
    "images": [{"bufferView": image_view, "mimeType": "image/png"}],
    "buffers": [{"byteLength": len(binary)}],
    "bufferViews": views,
    "accessors": accessors,
}
json_data = json.dumps(gltf, separators=(",", ":")).encode()
json_data += b" " * (-len(json_data) % 4)
binary += b"\0" * (-len(binary) % 4)
length = 12 + 8 + len(json_data) + 8 + len(binary)
glb = struct.pack("<III", 0x46546C67, 2, length)
glb += struct.pack("<II", len(json_data), 0x4E4F534A) + json_data
glb += struct.pack("<II", len(binary), 0x004E4942) + binary
(destination / "block.glb").write_bytes(glb)


def translation(east, north, up):
    return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, east, north, up, 1]


root = {
    "boundingVolume": {"box": [0, 0, 0, 20, 0, 0, 0, 20, 0, 0, 0, 5]},
    "geometricError": 100,
    "refine": "REPLACE",
    "transform": [0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 6378137, 0, 0, 1],
    # This coarse parent must not be included alongside its replacement children.
    "content": {"uri": "block.glb"},
    "children": [
        {"boundingVolume": {"sphere": [2, 2, 1, 6]}, "geometricError": 0,
         "transform": translation(-5, 0, 0), "content": {"uri": "block.glb"}},
        {"boundingVolume": {"sphere": [2, 2, 1, 6]}, "geometricError": 0,
         "transform": translation(5, 2, 0), "content": {"uri": "nested.json"}},
    ],
}
nested_root = {"boundingVolume": {"sphere": [2, 2, 1, 6]}, "geometricError": 0,
               "transform": translation(0, 0, 1), "content": {"uri": "block.glb"}}
for name, tile in [("tileset.json", root), ("nested.json", nested_root)]:
    (destination / name).write_text(json.dumps({"asset": {"version": "1.1"}, "geometricError": 100, "root": tile}, indent=2) + "\n")
print(f"Wrote original reference capture to {destination}")
