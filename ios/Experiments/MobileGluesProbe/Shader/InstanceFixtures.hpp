#pragma once
#include "DrawFixtures.hpp"
#include <stdexcept>
namespace rgpu::b12 {
inline constexpr int instanceCases = 3;
inline constexpr std::array<int,instanceCases> instanceCounts{4,2,0};
inline constexpr std::array<DrawCase,instanceCases> instanceInputs{{
    {1,1,-0.5f,-0.5f,0,{1,1,1,1},inputs[0].texture},
    {1,1,-0.5f,-0.5f,1,{0.5f,0.75f,1,1},inputs[2].texture},
    {1,1,-0.5f,-0.5f,0,{1,1,1,1},inputs[0].texture}
}};
inline Pixel expectedInstancePixel(int test, int x, int y) {
    const auto& input = instanceInputs.at(test);
    for (int instance = 0; instance < instanceCounts.at(test); ++instance) {
        const int left = input.left + (instance%2)*8, bottom = input.bottom + (instance/2)*8;
        if (x < left || x >= left+6 || y < bottom || y >= bottom+6) continue;
        Pixel result{};
        for (int c = 0; c < 4; ++c)
            result[c] = static_cast<std::uint8_t>(input.texture[instance][c]*input.tint[c]+0.5f);
        return result;
    }
    return {0,0,0,255};
}
// Same-context probe policy only, not a completion scheduler for RemoteGPU.
inline bool fenceComplete(unsigned result) {
    switch (result) {
        case 0x911a: case 0x911c: return true; // ALREADY_SIGNALED / CONDITION_SATISFIED
        case 0x911b: return false; // TIMEOUT_EXPIRED, not success
        default: throw std::runtime_error("Fence wait failed or returned invalid status");
    }
}
inline constexpr const char *instanceVertex = R"GLSL(#version 150
in vec2 aPosition;
uniform vec2 uOffset;
uniform vec2 uScale;
uniform vec2 uStep;
flat out ivec2 vCell;
void main() {
    vCell = ivec2(gl_InstanceID % 2, gl_InstanceID / 2);
    gl_Position = vec4(aPosition*uScale + uOffset + vec2(vCell)*uStep, 0.0, 1.0);
}
)GLSL";
inline constexpr const char *instanceFragment = R"GLSL(#version 150
flat in ivec2 vCell;
out vec4 outColor0;
uniform sampler2D uTex;
uniform vec4 uTint;
void main() { outColor0 = texelFetch(uTex, vCell, 0) * uTint; }
)GLSL";
}
