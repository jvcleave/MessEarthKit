#import "EarthDracoBridge.h"
#include <cstring>

namespace {
// Independent bounded cursor: no mesh, metadata tree or count-sized vector is
// allocated while reading the pinned Draco 1.x/2.x topology prefix.
struct Cursor {
    const uint8_t *bytes;
    size_t size;
    size_t offset = 0;
    size_t metadataItems = 0;

    bool byte(uint8_t &value) {
        if (offset >= size) { return false; }
        value = bytes[offset++];
        return true;
    }
    bool skip(uint64_t count) {
        if (count > size - offset) { return false; }
        offset += static_cast<size_t>(count);
        return true;
    }
    bool integer(uint64_t &value, bool varint) {
        value = 0;
        if (!varint) {
            for (int i = 0; i < 4; ++i) {
                uint8_t next;
                if (!byte(next)) { return false; }
                value |= uint64_t(next) << (8 * i);
            }
            return true;
        }
        for (int i = 0; i < 5; ++i) {
            uint8_t next;
            if (!byte(next) || (i == 4 && next > 15)) { return false; }
            value |= uint64_t(next & 127) << (7 * i);
            if ((next & 128) == 0) { return true; }
        }
        return false;
    }
    bool name() { uint8_t length; return byte(length) && skip(length); }
    bool metadata(unsigned depth) {
        if (depth > 32 || ++metadataItems > 4096) { return false; }
        uint64_t count;
        if (!integer(count, true) || count > 4096 - metadataItems) { return false; }
        metadataItems += count;
        for (uint64_t i = 0; i < count; ++i) {
            uint64_t length;
            if (!name() || !integer(length, true) || length == 0 || !skip(length)) { return false; }
        }
        if (!integer(count, true) || count > 4096 - metadataItems) { return false; }
        for (uint64_t i = 0; i < count; ++i) {
            if (!name() || !metadata(depth + 1)) { return false; }
        }
        return true;
    }
};
}

NSInteger EarthInspectDracoTopology(NSData *data, NSUInteger offset, NSUInteger length,
                                   uint64_t maximumPoints, uint64_t maximumFaces)
{
    if (offset > data.length || length > data.length - offset || length < 11 ||
        maximumPoints == 0 || maximumFaces == 0) { return 1; }
    const auto *bytes = static_cast<const uint8_t *>(data.bytes) + offset;
    if (std::memcmp(bytes, "DRACO", 5) != 0) { return 1; }
    const unsigned major = bytes[5], minor = bytes[6], type = bytes[7], method = bytes[8];
    const unsigned version = major * 256 + minor;
    const unsigned flags = bytes[9] | (unsigned(bytes[10]) << 8);
    if (major < 1 || major > 2 || (major == 2 && minor > 2) || type != 1 || method > 1 || (flags & ~0x8000) != 0) { return 2; }
    Cursor cursor{bytes, length, 11};
    if (version >= 0x0103 && (flags & 0x8000)) {
        uint64_t count;
        if (!cursor.integer(count, true) || count > 4096) { return 1; }
        for (uint64_t i = 0; i < count; ++i) {
            uint64_t id;
            if (!cursor.integer(id, true) || !cursor.metadata(0)) { return 1; }
        }
        if (!cursor.metadata(0)) { return 1; }
    }
    uint64_t faces = 0, points = 0;
    if (method == 0) {
        if (!cursor.integer(faces, version >= 0x0202) || !cursor.integer(points, version >= 0x0202)) { return 1; }
    } else {
        uint8_t traversal;
        if (!cursor.byte(traversal) || traversal > 2) { return 2; }
        uint64_t newVertices = 0, encodedVertices = 0;
        if (version < 0x0202 && !cursor.integer(newVertices, version >= 0x0200)) { return 1; }
        if (!cursor.integer(encodedVertices, version >= 0x0200) || !cursor.integer(faces, version >= 0x0200)) { return 1; }
        // Attribute seams can create more final points than encoded positions.
        // Three corners per face is a conservative bound, not a glTF declaration.
        if (encodedVertices > faces * 3) { return 1; }
        points = faces * 3 + newVertices;
    }
    if (faces == 0 || points == 0) { return 1; }
    return faces > maximumFaces || points > maximumPoints ? 3 : 0;
}
