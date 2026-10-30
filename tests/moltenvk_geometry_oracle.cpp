#include "Oracle.hpp"
#include <cassert>
#include <cstdio>
using namespace rgpu::geometry;
unsigned lit(const Pixels &p) {
    return std::count_if(p.begin(),p.end(),[](auto v){return v!=Color{0,0,0,255};});
}
int main() {
    assert(lit(expected(false,0,0))==1024);
    assert(expected(false,0,0)!=expected(false,0,1));
    for(int revision=0;revision<3;++revision) {
        assert(lit(expected(true,0,revision))==128);
        assert(lit(expected(true,1,revision))==16);
        assert(lit(expected(true,2,revision))==2);
        assert(lit(expected(true,3,revision))==128);
        assert(lit(expected(true,4,revision))==128);
        assert(lit(expected(true,5,revision))==128);
    }
    const auto p=expected(true,0,0);
    assert((p[4*W+2]==Color{255,0,0,255}));
    assert((p[4*W+16]==Color{255,0,0,255}));
    assert((p[3*W+2]==Color{0,0,0,255}));
    assert((p[4*W+10]==Color{0,0,0,255}));
    assert(p!=expected(true,0,1));
    assert(expected(true,0,1)!=expected(true,0,2));
    assert((expected(true,3,0)[18*W+2]==Color{0,0,255,255}));
    assert((expected(true,4,0)[4*W+16]==Color{0,0,255,255}));
    assert((expected(true,5,0)[4*W+2]==Color{16,16,128,255}));
    assert(matches({1,64,190,255},{0,64,191,255}));
    assert(!matches({2,64,191,255},{0,64,191,255}));
    assert(!matches({0,64,191,254},{0,64,191,255}));
    Pixels cleared; cleared.fill({0,0,0,255});
    unsigned mismatches=0;
    for(unsigned i=0;i<p.size();++i) mismatches+=!matches(cleared[i],p[i]);
    assert(mismatches==128); // A clear/no-op draw cannot pass the oracle.
    std::puts("PASS CPU oracle only; Vulkan/MoltenVK/iPhone execution NOT TESTED");
}
