// CPU oracle/fixture tests only; does NOT compile GLSL or simulate device draws.
#include "DrawFixtures.hpp"
#include <cassert>
#include <cstring>
#include <iostream>

int main() {
    using namespace rgpu::b12;
    static_assert(sizeof(Pixel) == 4 && sizeof(Vertex) == sizeof(float)*4);
    assert(std::strncmp(vertexSource,"#version 150\n",13) == 0);
    assert(std::strncmp(fragmentSource,"#version 150\n",13) == 0);
    for (const auto& input : inputs) {
        // Independent integer rectangle matches the actual vertex uniforms.
        assert((input.offsetX-scaleX+1)*width/2 == input.left);
        assert((input.offsetY-scaleY+1)*height/2 == input.bottom);
        int colored = 0;
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            const auto expected = expectedPixel(input,x,y);
            if (expected != Pixel{0,0,0,255}) ++colored;
            assert(matches(expected,expected));
            Pixel bad = expected; bad[3] = 254; assert(!matches(bad,expected));
            // A missing draw/clear-only image must not pass a drawn pixel.
            if (x >= input.left && x < input.left+6 && y >= input.bottom && y < input.bottom+12)
                assert(!matches(Pixel{0,0,0,255},expected));
        }
        assert(colored == 72);
        assert(expectedPixel(input,input.left-1,input.bottom) == Pixel({0,0,0,255}));
    }
    // Literal corner fixtures independently catch wrong texture row/order/tint.
    assert(expectedPixel(inputs[0],1,2) == Pixel({255,0,0,255}));
    assert(expectedPixel(inputs[0],6,2) == Pixel({0,255,0,255}));
    assert(expectedPixel(inputs[0],1,13) == Pixel({0,0,255,255}));
    assert(expectedPixel(inputs[1],9,2) == Pixel({128,0,0,255}));
    assert(expectedPixel(inputs[1],14,2) == Pixel({0,191,0,255}));
    assert(expectedPixel(inputs[2],1,0) == Pixel({32,64,224,255}));
    int positionDifferences = 0, inputDifferences = 0;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        positionDifferences += expectedPixel(inputs[0],x,y) != expectedPixel(inputs[1],x,y);
        inputDifferences += expectedPixel(inputs[0],x,y) != expectedPixel(inputs[2],x,y);
    }
    assert(positionDifferences == 144 && inputDifferences > 72);
    assert(matches(Pixel{50,154,229,255},Pixel{51,153,230,255}));
    assert(!matches(Pixel{49,153,230,255},Pixel{51,153,230,255}));
    std::cout << "PASS: B1.2a oracle geometry, texture rows, tint, dynamic differences, clear-only rejection and fixed tolerance; NOT GLSL/device execution\n";
}
