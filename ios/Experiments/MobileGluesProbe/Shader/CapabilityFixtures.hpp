#pragma once
#include "DrawFixtures.hpp"
#include <stdexcept>

namespace rgpu::b12 {
enum class Capability { SignedBuffer, FloatBuffer, Geometry };
enum class Verdict { NotRun, Passed, Blocked };
inline constexpr std::array<Capability,3> capabilityKinds{
    Capability::SignedBuffer,Capability::FloatBuffer,Capability::Geometry};
inline constexpr std::array<const char*,3> capabilityNames{
    "TBO_R8I", "TBO_RGBA32F", "GEOMETRY_GLSL150"};
inline bool allCapabilitiesPassed(const std::array<Verdict,3>& verdicts) {
    for (auto value : verdicts) if (value != Verdict::Passed) return false;
    return true;
}
inline constexpr int bufferCases = 3, geometryCases = 2;
inline constexpr std::array<std::int8_t,4> signedInitial{-128,-64,0,127};
inline constexpr std::array<std::int8_t,4> signedUpdated{-32,32,96,-96};
inline constexpr std::array<float,16> floatInitial{
    1,0,0,1, 0,1,0,1, 0,0,1,1, 1,1,1,1};
inline constexpr std::array<float,16> floatUpdated{
    0,1,1,1, 1,0,1,1, 1,1,0,1, 0,0,0,1};
inline Pixel expectedBufferPixel(Capability kind,int test,int x,int y) {
    if (kind == Capability::Geometry || test < 0 || test >= bufferCases)
        throw std::out_of_range("Invalid buffer fixture");
    const int cell = (x/8) + 2*(y/8);
    const int index = (cell + (test == 0 ? 0 : 1)) % 4;
    if (kind == Capability::SignedBuffer) {
        const auto& data = test == 0 ? signedInitial : signedUpdated;
        return {static_cast<std::uint8_t>(int(data[index])+128),64,191,255};
    }
    const auto& data = test == 0 ? floatInitial : floatUpdated;
    Pixel pixel{};
    for (int c = 0; c < 4; ++c) pixel[c] = static_cast<std::uint8_t>(255*data[4*index+c]);
    return pixel;
}
inline Pixel expectedGeometryPixel(int test,int x,int y) {
    if (test < 0 || test >= geometryCases) throw std::out_of_range("Invalid geometry fixture");
    const int left = test == 0 ? 1 : 9;
    if (x < left || x >= left+6 || y < 2 || y >= 14) return {0,0,0,255};
    return test == 0 ? Pixel{255,64,0,255} : Pixel{0,128,255,255};
}
inline constexpr const char *capabilityVertex = R"GLSL(#version 150
in vec2 aPosition;
void main() { gl_Position = vec4(aPosition, 0.0, 1.0); }
)GLSL";
inline constexpr const char *signedBufferFragment = R"GLSL(#version 150
uniform isamplerBuffer uBuffer;
uniform int uBias;
out vec4 outColor0;
void main() {
    int cell = int(gl_FragCoord.x)/8 + 2*(int(gl_FragCoord.y)/8);
    int index = (cell + uBias) % 4;
    int value = texelFetch(uBuffer, index).r;
    outColor0 = vec4(float(value + 128)/255.0, 0.25, 0.75, 1.0);
}
)GLSL";
inline constexpr const char *floatBufferFragment = R"GLSL(#version 150
uniform samplerBuffer uBuffer;
uniform int uBias;
out vec4 outColor0;
void main() {
    int cell = int(gl_FragCoord.x)/8 + 2*(int(gl_FragCoord.y)/8);
    int index = (cell + uBias) % 4;
    outColor0 = texelFetch(uBuffer, index);
}
)GLSL";
inline constexpr const char *geometrySource = R"GLSL(#version 150
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
uniform vec2 uScale;
uniform vec2 uOffset;
uniform vec4 uColor;
out vec4 gColor;
void main() {
    for (int i = 0; i < 3; ++i) {
        gl_Position = vec4(gl_in[i].gl_Position.xy * uScale + uOffset, 0.0, 1.0);
        gColor = uColor;
        EmitVertex();
    }
    EndPrimitive();
}
)GLSL";
inline constexpr const char *geometryFragment = R"GLSL(#version 150
in vec4 gColor;
out vec4 outColor0;
void main() { outColor0 = gColor; }
)GLSL";
}
