#include <metal_stdlib>
using namespace metal;

struct DisplayVertex {
    float4 position [[position]];
    float2 uv;
};

vertex DisplayVertex displayVertex(uint id [[vertex_id]]) {
    const float2 points[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    DisplayVertex output;
    output.position = float4(points[id], 0, 1);
    // Screen top samples GL's high-Y row, correcting the IOSurface inversion.
    output.uv = (points[id] + 1) * 0.5;
    return output;
}

fragment float4 displayFragment(DisplayVertex input [[stage_in]],
                                texture2d<float> image [[texture(0)]]) {
    constexpr sampler sampling(coord::normalized, address::clamp_to_edge, filter::nearest);
    return image.sample(sampling, input.uv);
}
