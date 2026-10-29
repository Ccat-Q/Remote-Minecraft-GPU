// Exercise the actual CPU oracle only; no GPU, shader or raster acceptance.
#include "RasterFixtures.hpp"
#include <cassert>
#include <cstring>
#include <iostream>
int main() {
    using namespace rgpu::b12;
    assert(std::strstr(rasterVertex,"#version 150\n"));
    assert(std::strstr(rasterVertex,"uDepth, 1.0"));
    for (int test = 0; test < rasterCases; ++test) {
        int counts[4]{};
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            Pixel literal{};
            if (test < 2) {
                const bool inner = x >= 6 && x < 10 && y >= 6 && y < 10;
                const bool base = x >= 2 && x < 14 && y >= 2 && y < 14;
                literal = inner ? (test == 0 ? Pixel{0,255,0,255} : Pixel{255,255,0,255}) :
                          base ? Pixel{255,0,0,255} : Pixel{0,0,0,255};
                ++counts[inner ? 0 : base ? 1 : 2];
            } else if (test == 2) {
                const bool marked = x >= 2 && x < 8 && y >= 2 && y < 14;
                literal = marked ? Pixel{255,0,0,255} : Pixel{0,255,0,255};
                ++counts[marked ? 0 : 1];
            } else {
                const bool r = x >= 1 && x <= 10 && y >= 1 && y <= 10;
                const bool g = x >= 5 && x <= 14 && y >= 5 && y <= 14;
                literal = r && g ? Pixel{96,64,96,255} : r ? Pixel{128,0,128,255} :
                          g ? Pixel{0,64,191,255} : Pixel{0,0,255,255};
                ++counts[r && g ? 0 : r ? 1 : g ? 2 : 3];
            }
            const auto actual = expectedRasterPixel(test,x,y);
            assert(actual == literal);
            assert(!matches(actual,Pixel{0,0,0,0})); // zero/uninitialized read cannot pass
            auto wrongAlpha = actual; wrongAlpha[3] = 254;
            assert(!matches(wrongAlpha,actual));
        }
        if (test < 2) assert(counts[0] == 16 && counts[1] == 128 && counts[2] == 112);
        else if (test == 2) assert(counts[0] == 72 && counts[1] == 184);
        else assert(counts[0] == 36 && counts[1] == 64 && counts[2] == 64 && counts[3] == 92);
    }
    assert(expectedRasterPixel(0,6,6) != expectedRasterPixel(1,6,6));
    auto quantized = expectedRasterPixel(3,5,5); ++quantized[0];
    assert(matches(quantized,expectedRasterPixel(3,5,5)));
    ++quantized[0]; assert(!matches(quantized,expectedRasterPixel(3,5,5)));
    for (int invalid : {-1,4}) {
        bool threw = false;
        try { (void)expectedRasterPixel(invalid,0,0); } catch (const std::out_of_range&) { threw = true; }
        assert(threw);
    }
    std::cout << "PASS: B1.2c actual CPU oracle, four complete 16x16 golden grids, fixed tolerances; NOT device raster execution\n";
}
