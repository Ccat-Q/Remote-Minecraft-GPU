#pragma once
#include "DrawFixtures.hpp"
#include <stdexcept>
namespace rgpu::b12 {
inline constexpr int rasterCases = 4;
inline constexpr std::array<const char*,rasterCases> rasterNames{
    "DEPTH_LESS_OCCLUSION", "DEPTH_WRITE_MASK", "STENCIL_COMPARE_OP_WRITE_MASK", "BLEND_SEPARATE_RGB_ALPHA"};
inline constexpr DrawCase rasterInput{0,0,0,0,0,{1,1,1,1},
    {{{255,255,255,255},{255,255,255,255},{255,255,255,255},{255,255,255,255}}}};
inline bool inRect(int x,int y,int left,int bottom,int w,int h) {
    return x >= left && x < left+w && y >= bottom && y < bottom+h;
}
inline Pixel expectedRasterPixel(int test,int x,int y) {
    if (test == 0 || test == 1) {
        if (inRect(x,y,6,6,4,4)) return test == 0 ? Pixel{0,255,0,255} : Pixel{255,255,0,255};
        return inRect(x,y,2,2,12,12) ? Pixel{255,0,0,255} : Pixel{0,0,0,255};
    }
    if (test == 2) return inRect(x,y,2,2,6,12) ? Pixel{255,0,0,255} : Pixel{0,255,0,255};
    if (test == 3) {
        const bool red = inRect(x,y,1,1,10,10), green = inRect(x,y,5,5,10,10);
        if (red && green) return {96,64,96,255};
        if (red) return {128,0,128,255};
        if (green) return {0,64,191,255};
        return {0,0,255,255};
    }
    throw std::out_of_range("Invalid raster test");
}
inline constexpr const char *rasterVertex = R"GLSL(#version 150
in vec2 aPosition;
in vec2 aUV;
out vec2 vUV;
uniform vec2 uOffset;
uniform vec2 uScale;
uniform float uDepth;
void main() {
    gl_Position = vec4(aPosition * uScale + uOffset, uDepth, 1.0);
    vUV = aUV;
}
)GLSL";
}
