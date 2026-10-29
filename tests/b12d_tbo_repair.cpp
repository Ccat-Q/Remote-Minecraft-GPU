// Tests the ACTUAL dependency/range/translation helpers, NOT GPU execution.
#include "TBOAttachments.hpp"
#include "TBOSamplers.hpp"
#include <cassert>
#include <iostream>
#include <limits>

int main(int argc, char**) {
    using namespace rgpu::tbo;
    const std::string shader = "#version 150\n"
        "uniform samplerBuffer uFloat;\nuniform isamplerBuffer uSigned;\n"
        "uniform sampler2D ordinary;\nout vec4 color;\n"
        "// samplerBuffer commentOnly; texelFetch(commentOnly, (1+2))\n"
        "void main() { int index=1; color=texelFetch(uFloat, (index+int(1)))"
        "+vec4(texelFetch(uSigned, index))+texelFetch(ordinary, ivec2(0), 0); }\n";
    const auto result = lowerSamplers(shader,shader.find('\n')+1);
    if (argc > 1) { std::cout << result; return 0; }
    assert(result.find("uniform sampler2D uFloat;") != std::string::npos);
    assert(result.find("uniform isampler2D uSigned;") != std::string::npos);
    assert(result.find("rgpuBufferFetch(uFloat, (index+int(1)))") != std::string::npos);
    assert(result.find("texelFetch(ordinary, ivec2(0), 0)") != std::string::npos);
    assert(result.find("// samplerBuffer commentOnly; texelFetch(commentOnly, (1+2))") != std::string::npos);
    assert(result.find("ivec4 rgpuBufferFetch(isampler2D") != std::string::npos);
    const auto unsignedResult = lowerSamplers("uniform usamplerBuffer u;\nvoid f(){texelFetch(u,2);}",0);
    assert(unsignedResult.find("uvec4 rgpuBufferFetch(usampler2D") != std::string::npos);
    const std::string plain = "uniform sampler2D u;\nvoid f(){texelFetch(u,ivec2(0),0);}";
    assert(lowerSamplers(plain,0) == plain);
    for (const auto* invalid : {"uniform samplerBuffer u[2];", "uniform samplerBuffer u; int rgpuBufferFetch;"}) {
        bool rejected = false;
        try { lowerSamplers(invalid,0); } catch (const std::runtime_error&) { rejected = true; }
        assert(rejected);
    }
    Attachments group, otherGroup;
    group.attach(11,7,1); group.attach(12,7,2); otherGroup.attach(11,8,3);
    assert(group.forBuffer(7).size() == 2 && otherGroup.forBuffer(7).empty());
    group.attach(11,8,1); // reattach one texture to a different buffer
    assert(group.forBuffer(7).size() == 1 && group.forBuffer(8).size() == 1);
    group.eraseBuffer(7); // deletion must not link a recycled buffer name
    assert(group.forBuffer(7).empty());
    group.attach(13,7,1); assert(group.forBuffer(7).size() == 1);
    group.eraseTexture(13); assert(group.forBuffer(7).empty());
    group.attach(11,0,0); assert(group.forBuffer(8).empty());
    assert(otherGroup.forBuffer(8).size() == 1);
    auto range = spans(20,1,8,6,13); // row crossing + short final row
    assert(range.size() == 3 && range[0].x == 6 && range[0].count == 2);
    assert(range[1].row == 1 && range[1].count == 8 && range[1].byteOffset == 8);
    assert(range[2].row == 2 && range[2].count == 3 && range[2].byteOffset == 16);
    range = spans(64,16,4,17,1); // partial RGBA32F texel update
    assert(range.size() == 1 && range[0].x == 1 && range[0].count == 1 && range[0].byteOffset == 16);
    assert(spans(4,1,4,4,1).empty());
    assert(spans(4,1,4,1,std::numeric_limits<std::size_t>::max()).empty());
    assert(spans(4,0,4,0,4).empty() && spans(4,1,0,0,4).empty());
    std::cout << "PASS: actual TBO attachment/range/typed-lowering helpers; NOT GPU execution\n";
}
