#include "EarthMeshOptimizer.h"
#include "vendor/meshoptimizer.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>

EMOResult EMOOptimize(const EMOVertex *vertices, size_t vertexCount,
    const uint32_t *indices, size_t indexCount, float fraction,
    float error, int preservesTriangleOrder)
{
    EMOResult result = {};
    if (!vertices || !indices || !vertexCount || !indexCount || indexCount % 3
        || !std::isfinite(fraction) || fraction <= 0 || fraction > 1
        || !std::isfinite(error) || error < 0) { result.status = 1; return result; }
    for (size_t i = 0; i < indexCount; ++i)
        if (indices[i] >= vertexCount) { result.status = 1; return result; }
    try {
        std::vector<unsigned int> remap(vertexCount);
        size_t unique = meshopt_generateVertexRemap(remap.data(), indices, indexCount,
            vertices, vertexCount, sizeof(EMOVertex));
        std::vector<EMOVertex> compact(unique);
        std::vector<unsigned int> topology(indexCount);
        meshopt_remapVertexBuffer(compact.data(), vertices, vertexCount, sizeof(EMOVertex), remap.data());
        meshopt_remapIndexBuffer(topology.data(), indices, indexCount, remap.data());
        // Alpha-blended meshes keep their authored triangle order and topology.
        if (!preservesTriangleOrder && fraction < 1 && error > 0) {
            size_t target = std::max(size_t(3), size_t(double(indexCount / 3) * fraction) * 3);
            std::vector<unsigned int> simplified(indexCount);
            const float weights[9] = {1, 1, 1, 10, 10, 1, 1, 1, 1};
            size_t count = meshopt_simplifyWithAttributes(simplified.data(), topology.data(),
                topology.size(), compact[0].position, compact.size(), sizeof(EMOVertex),
                compact[0].normal, sizeof(EMOVertex), weights, 9, nullptr, target, error,
                meshopt_SimplifyLockBorder | meshopt_SimplifyErrorAbsolute, &result.errorMeters);
            if (count >= 3) { simplified.resize(count); topology.swap(simplified); }
            // Edge collapse can leave distinct but exactly collinear vertices.
            // Test delivered positions in Double, without an area threshold,
            // so tiny valid faces survive and consumers can generate normals.
            size_t write = 0;
            for (size_t i = 0; i < topology.size(); i += 3) {
                const float *a = compact[topology[i]].position;
                const float *b = compact[topology[i + 1]].position;
                const float *c = compact[topology[i + 2]].position;
                double ab[3], ac[3];
                for (int axis = 0; axis < 3; ++axis) {
                    ab[axis] = double(b[axis]) - double(a[axis]);
                    ac[axis] = double(c[axis]) - double(a[axis]);
                }
                if (ab[1] * ac[2] == ab[2] * ac[1]
                    && ab[2] * ac[0] == ab[0] * ac[2]
                    && ab[0] * ac[1] == ab[1] * ac[0]) continue;
                for (size_t corner = 0; corner < 3; ++corner)
                    topology[write++] = topology[i + corner];
            }
            topology.resize(write);
            if (topology.empty()) { result.status = 1; return result; }
        }
        if (!preservesTriangleOrder)
            meshopt_optimizeVertexCache(topology.data(), topology.data(), topology.size(), compact.size());
        std::vector<EMOVertex> fetched(compact.size());
        size_t used = meshopt_optimizeVertexFetch(fetched.data(), topology.data(), topology.size(),
            compact.data(), compact.size(), sizeof(EMOVertex));
        result.vertices = static_cast<EMOVertex *>(std::malloc(used * sizeof(EMOVertex)));
        result.indices = static_cast<uint32_t *>(std::malloc(topology.size() * sizeof(uint32_t)));
        if (!result.vertices || !result.indices) { EMORelease(result); return {nullptr, nullptr, 0, 0, 0, 2}; }
        std::memcpy(result.vertices, fetched.data(), used * sizeof(EMOVertex));
        std::memcpy(result.indices, topology.data(), topology.size() * sizeof(uint32_t));
        result.vertexCount = used; result.indexCount = topology.size();
        return result;
    } catch (...) { EMORelease(result); return {nullptr, nullptr, 0, 0, 0, 2}; }
}

void EMORelease(EMOResult result) { std::free(result.vertices); std::free(result.indices); }
