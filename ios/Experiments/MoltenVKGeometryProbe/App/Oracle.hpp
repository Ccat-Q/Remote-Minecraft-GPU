#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace rgpu::geometry {
inline constexpr uint32_t W=32,H=32;
using Color=std::array<uint8_t,4>;
using Pixels=std::array<Color,W*H>;
inline bool matches(Color actual,Color oracle) {
    for(int channel=0;channel<4;++channel)
        if(std::abs(int(actual[channel])-int(oracle[channel]))>(channel==3?0:1)) return false;
    return true;
}
// Pure CPU oracle shared by the actual app and Actions sanitizer tests.
// Pixel centers and shapes use exact binary-fraction coordinates.
inline Pixels expected(bool geometry,int kind,int revision) {
    Pixels result; result.fill({0,0,0,255});
    if(!geometry) { result.fill(revision?Color{0,255,0,255}:Color{255,0,0,255}); return result; }
    float ox=-.875f+(revision?.125f:0)+(revision==2?.125f:0), oy=-.75f+(revision?.125f:0);
    if(kind==1 || kind==2) { ox=-.65625f+(revision?.125f:0)+(revision==2?.125f:0); oy=-.65625f+(revision?.125f:0); }
    Color base=revision?Color{0,uint8_t(revision==2?128:255),0,255}:Color{255,0,0,255};
    for(uint32_t y=0;y<H;++y) for(uint32_t x=0;x<W;++x) {
        float px=(x+.5f)/16-1, py=(y+.5f)/16-1;
        for(int j=0;j<2;++j) {
            float left=ox+(kind==3?0:j*.875f), top=oy+(kind==3?j*.875f:0);
            bool covered=px>=left && px<left+.5f && py>=top && py<top+.5f;
            if(kind==1) covered=px>=left && px<left+.5f && std::abs(py-top)<.02f;
            if(kind==2) covered=std::abs(px-left)<.02f && std::abs(py-top)<.02f;
            if(!covered) continue;
            Color color=base;
            if((kind==3 || kind==4) && j) std::swap(color[0],color[2]);
            if(kind==5) color={uint8_t(std::lround((px-left)*510)),uint8_t(std::lround((py-top)*510)),128,255};
            result[y*W+x]=color;
        }
    }
    return result;
}
}
