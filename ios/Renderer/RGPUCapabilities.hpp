#pragma once
#include <cstddef>
#include <cstdint>
#include <stdexcept>

namespace rgpu {
struct CapsetSummary {
    uint32_t glslLevel;
    uint32_t renderTargets;
    uint32_t samples;
    uint32_t uniformBlocks;
    bool meetsGlslThreshold() const { return glslLevel >= 150; }
};
// Pinned virgl_hw.h's 308-byte v1 prefix; capset 2 embeds it unchanged.
// Input excludes the vtest reply header. Never infer guest GL_VERSION here.
inline CapsetSummary summarizeCaps(uint32_t id, const uint8_t* bytes, size_t length) {
    if ((id != 1 && id != 2) || !bytes || length < 308)
        throw std::runtime_error("invalid or truncated VirGL capset summary");
    const auto word = [bytes](size_t at) {
        return uint32_t(bytes[at]) | uint32_t(bytes[at+1]) << 8 |
            uint32_t(bytes[at+2]) << 16 | uint32_t(bytes[at+3]) << 24;
    };
    return {word(264), word(280), word(284), word(296)};
}
}
