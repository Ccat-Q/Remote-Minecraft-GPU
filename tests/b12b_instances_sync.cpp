// Exact oracle/status policy only. NOT GPU, GLSL or Fence device execution.
#include "InstanceFixtures.hpp"
#include <cassert>
#include <iostream>
#include <cstring>
int main() {
    using namespace rgpu::b12;
    assert(std::strstr(instanceVertex,"#version 150\n"));
    assert(std::strstr(instanceVertex,"gl_InstanceID"));
    assert(std::strstr(instanceFragment,"flat in ivec2"));
    for (int test = 0; test < instanceCases; ++test) {
        int covered = 0;
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x)
            covered += expectedInstancePixel(test,x,y) != Pixel{0,0,0,255};
        assert(covered == instanceCounts[test]*36);
    }
    assert((expectedInstancePixel(0,1,1) == Pixel{255,0,0,255}));
    assert((expectedInstancePixel(0,9,1) == Pixel{0,255,0,255}));
    assert((expectedInstancePixel(0,1,9) == Pixel{0,0,255,255}));
    assert((expectedInstancePixel(0,9,9) == Pixel{255,255,255,255}));
    assert((expectedInstancePixel(1,1,1) == Pixel{16,48,224,255}));
    assert((expectedInstancePixel(1,1,9) == Pixel{0,0,0,255}));
    assert((expectedInstancePixel(2,1,1) == Pixel{0,0,0,255}));
    assert((expectedInstancePixel(0,7,1) == Pixel{0,0,0,255})); // gap, not a stretched draw
    assert(fenceComplete(0x911a) && fenceComplete(0x911c));
    assert(!fenceComplete(0x911b)); // never count a timeout as completion
    for (unsigned bad : {0u,0x911du,0xffffffffu}) {
        bool threw = false;
        try { (void)fenceComplete(bad); } catch (const std::runtime_error&) { threw = true; }
        assert(threw);
    }
    std::cout << "PASS: B1.2b actual instance oracle (4/2/0, identity/position/palette/count) and Fence status policy; NOT device execution\n";
}
