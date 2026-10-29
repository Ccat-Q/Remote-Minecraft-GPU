#pragma once
#include <array>
#include <cstdint>
#include <cstdlib>

namespace rgpu::b12 {
inline constexpr int width = 16, height = 16, cases = 3;
using Pixel = std::array<std::uint8_t, 4>;
struct Vertex { float x, y, u, v; };
inline constexpr std::array<Vertex, 6> vertices{{
    {-1,-1,0,0}, {1,-1,1,0}, {-1,1,0,1},
    {-1,1,0,1}, {1,-1,1,0}, {1,1,1,1}}};
struct DrawCase {
    int left, bottom;
    float offsetX, offsetY;
    int textureUnit;
    std::array<float,4> tint;
    std::array<Pixel,4> texture; // bottom row first, GL upload convention
};
inline constexpr std::array<DrawCase,cases> inputs{{
    {1,2,-0.5f,0,0,{1,1,1,1}, {{{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}}}},
    {9,2, 0.5f,0,1,{0.5f,0.75f,1,1}, {{{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}}}},
    {1,0,-0.5f,-0.25f,0,{1,1,1,1}, {{{32,64,224,255},{224,32,64,255},{64,224,32,255},{192,128,64,255}}}}
}};
inline constexpr float scaleX = 0.375f, scaleY = 0.75f; // 6x12 pixel rectangle
inline Pixel expectedPixel(const DrawCase& input, int x, int y) {
    if (x < input.left || x >= input.left + 6 || y < input.bottom || y >= input.bottom + 12)
        return {0,0,0,255};
    const int index = ((y - input.bottom) / 6) * 2 + (x - input.left) / 3;
    Pixel result{};
    for (int channel = 0; channel < 4; ++channel)
        result[channel] = static_cast<std::uint8_t>(input.texture[index][channel] * input.tint[channel] + 0.5f);
    return result;
}
inline bool matches(const Pixel& actual, const Pixel& expected) {
    for (int c = 0; c < 4; ++c)
        if (std::abs(int(actual[c])-int(expected[c])) > (c == 3 ? 0 : 1)) return false;
    return true;
}
inline constexpr const char *vertexSource = R"GLSL(#version 150
in vec2 aPosition;
in vec2 aUV;
out vec2 vUV;
uniform vec2 uOffset;
uniform vec2 uScale;
void main() {
    gl_Position = vec4(aPosition * uScale + uOffset, 0.0, 1.0);
    vUV = aUV;
}
)GLSL";
inline constexpr const char *fragmentSource = R"GLSL(#version 150
in vec2 vUV;
out vec4 outColor0;
uniform sampler2D uTex;
uniform vec4 uTint;
void main() {
    outColor0 = texture(uTex, vUV) * uTint;
}
)GLSL";
}
