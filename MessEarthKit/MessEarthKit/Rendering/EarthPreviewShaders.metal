#include <metal_stdlib>
using namespace metal;

struct EarthVertex
{
    float3 position;
    float3 normal;
    float2 textureCoordinate;
    float4 color;
};

struct RasterVertex
{
    float4 position [[position]];
    float3 normal;
    float2 textureCoordinate;
    float4 color;
};

struct SurfaceUniforms
{
    float4 baseColor;
    float4 options;
};

vertex RasterVertex earthPreviewVertex(
    uint vertexID [[vertex_id]],
    const device EarthVertex *vertices [[buffer(0)]],
    constant float4x4 &viewProjection [[buffer(1)]]
)
{
    EarthVertex input = vertices[vertexID];
    return { viewProjection * float4(input.position, 1), input.normal, input.textureCoordinate, input.color };
}

fragment float4 earthPreviewFragment(
    RasterVertex input [[stage_in]],
    bool frontFacing [[front_facing]],
    constant SurfaceUniforms &surface [[buffer(0)]],
    texture2d<float> image [[texture(0)]],
    sampler imageSampler [[sampler(0)]]
)
{
    float4 color = image.sample(imageSampler, input.textureCoordinate) * surface.baseColor * input.color;
    if (surface.options.y >= 0 && color.a < surface.options.y) { discard_fragment(); }
    if (surface.options.z > 0.5) { color.a = 1; }
    if (surface.options.x < 0.5)
    {
        float3 normal = normalize(input.normal) * (frontFacing ? 1.0 : -1.0);
        float diffuse = max(0.0, dot(normal, normalize(float3(0.4, 0.8, 0.6))));
        color.rgb *= 0.3 + 0.7 * diffuse;
    }
    return color;
}
