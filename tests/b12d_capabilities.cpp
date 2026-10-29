// Test only real CPU oracle / aggregation policy; NOT device functionality.
#include "CapabilityFixtures.hpp"
#include <cassert>
#include <cstring>
#include <iostream>
int main() {
    using namespace rgpu::b12;
    for (auto source : {capabilityVertex,signedBufferFragment,floatBufferFragment,geometrySource,geometryFragment}) {
        assert(std::strstr(source,"#version 150\n"));
        assert(!std::strstr(source,"#version 300"));
    }
    const std::array<std::array<Pixel,4>,2> signedGolden{{
        {{{0,64,191,255},{64,64,191,255},{128,64,191,255},{255,64,191,255}}},
        {{{160,64,191,255},{224,64,191,255},{32,64,191,255},{96,64,191,255}}}}};
    const std::array<std::array<Pixel,4>,2> floatGolden{{
        {{{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}}},
        {{{255,0,255,255},{255,255,0,255},{0,0,0,255},{0,255,255,255}}}}};
    for (int test = 0; test < bufferCases; ++test) {
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            const int cell = (x < 8 ? 0 : 1) + (y < 8 ? 0 : 2);
            assert(expectedBufferPixel(Capability::SignedBuffer,test,x,y) == signedGolden[test == 0 ? 0 : 1][cell]);
            assert(expectedBufferPixel(Capability::FloatBuffer,test,x,y) == floatGolden[test == 0 ? 0 : 1][cell]);
            if (test) { // a stale attachment after glBufferSubData must NOT pass
                assert(!matches(expectedBufferPixel(Capability::SignedBuffer,0,x,y),signedGolden[1][cell]));
                assert(!matches(expectedBufferPixel(Capability::FloatBuffer,0,x,y),floatGolden[1][cell]));
            }
        }
    }
    for (int test = 0; test < geometryCases; ++test) {
        int covered = 0;
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            const bool inside = x >= (test ? 9 : 1) && x <= (test ? 14 : 6) && y >= 2 && y <= 13;
            const Pixel literal = inside ? (test ? Pixel{0,128,255,255} : Pixel{255,64,0,255}) : Pixel{0,0,0,255};
            assert(expectedGeometryPixel(test,x,y) == literal); covered += inside;
        }
        assert(covered == 72);
    }
    const auto pass = Verdict::Passed, blocked = Verdict::Blocked, notRun = Verdict::NotRun;
    assert(allCapabilitiesPassed({pass,pass,pass}));
    assert(!allCapabilitiesPassed({notRun,notRun,notRun}));
    assert(!allCapabilitiesPassed({blocked,pass,pass}));
    assert(!allCapabilitiesPassed({pass,blocked,pass}));
    assert(!allCapabilitiesPassed({pass,pass,blocked}));
    assert(!allCapabilitiesPassed({pass,pass,notRun}));
    for (int invalid : {-1,3}) {
        bool threw = false;
        try { (void)expectedBufferPixel(Capability::SignedBuffer,invalid,0,0); }
        catch (const std::out_of_range&) { threw = true; }
        assert(threw);
    }
    std::cout << "PASS: B1.2d actual CPU signed/float TBO update and GS output oracles, no-pass-on-blocked/not-run policy; NOT GPU execution\n";
}
