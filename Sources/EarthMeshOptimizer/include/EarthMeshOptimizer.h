#ifndef EARTH_MESH_OPTIMIZER_H
#define EARTH_MESH_OPTIMIZER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { float position[3], normal[3], uv[2], color[4]; } EMOVertex;
typedef struct {
    EMOVertex *vertices;
    uint32_t *indices;
    size_t vertexCount, indexCount;
    float errorMeters;
    int status;
} EMOResult;
EMOResult EMOOptimize(const EMOVertex *vertices, size_t vertexCount,
    const uint32_t *indices, size_t indexCount, float triangleFraction,
    float maximumErrorMeters, int preservesTriangleOrder);
void EMORelease(EMOResult result);
#ifdef __cplusplus
}
#endif
#endif
