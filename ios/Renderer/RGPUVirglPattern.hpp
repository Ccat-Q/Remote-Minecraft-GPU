#pragma once
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <vector>

// Minimal ABI subset of UTM virgl_protocol.h @ 482f9d8. No GLES drawing,
// pixel uploads or readbacks: all pattern content is produced by VirGL CLEAR
// and RESOURCE_COPY_REGION, carried through the existing legacy vtest decoder.
namespace rgpu::pattern {
constexpr uint32_t width = 640, height = 360, resource = 42, scratch = 43;
constexpr uint32_t format = 67, target = 2, samples = 0; // RGBA8, PIPE_TEXTURE_2D, single-sample.
inline void word(std::vector<uint8_t>& out, uint32_t value) {
    for (unsigned shift = 0; shift < 32; shift += 8) out.push_back(uint8_t(value >> shift));
}
inline std::vector<uint8_t> message(uint32_t command, const std::vector<uint32_t>& args) {
    std::vector<uint8_t> out;
    word(out, uint32_t(args.size())); word(out, command);
    for (auto value : args) word(out, value);
    return out;
}
inline std::vector<uint8_t> createContext() {
    std::vector<uint8_t> out;
    word(out, 4); word(out, 8); out.insert(out.end(), {'a', '2', '0', 0});
    return out;
}
inline std::vector<uint8_t> createResource(uint32_t handle, uint32_t colorFormat = format) {
    return message(2, {handle, target, colorFormat, 2 | 8, width, height, 1, 1, 0, samples});
}
inline void command(std::vector<uint32_t>& out, uint32_t opcode, uint32_t object,
                    std::initializer_list<uint32_t> args) {
    out.push_back(opcode | (object << 8) | (uint32_t(args.size()) << 16));
    out.insert(out.end(), args);
}
inline uint32_t bits(float value) { uint32_t result; std::memcpy(&result, &value, 4); return result; }
inline void clear(std::vector<uint32_t>& out, uint32_t surface, float r, float g, float b) {
    command(out, 5, 0, {1, 0, surface}); // SET_FRAMEBUFFER_STATE
    command(out, 7, 0, {4, bits(r), bits(g), bits(b), bits(1), 0, 0, 0}); // CLEAR_COLOR0
}
inline std::vector<uint8_t> render(uint32_t colorFormat = format) {
    std::vector<uint32_t> out;
    command(out, 1, 8, {100, resource, colorFormat, 0, 0}); // CREATE_OBJECT(SURFACE)
    command(out, 1, 8, {101, scratch, colorFormat, 0, 0});
    clear(out, 100, .02f, .04f, .08f);
    struct Rectangle { uint32_t x, y, w, h; float r, g, b; };
    // Raw GL coordinates: high Y is the top on screen after the ONE existing
    // Metal display orientation transform. Asymmetry detects double flips.
    const Rectangle rectangles[] = {
        {32, 220, 160, 108, 1, 0, 0}, {440, 260, 140, 60, 0, 1, 0},
        {60, 32, 100, 80, 0, 0, 1}, {350, 40, 220, 100, 1, 1, 0}
    };
    for (const auto& rect : rectangles) {
        clear(out, 101, rect.r, rect.g, rect.b);
        command(out, 17, 0, {resource, 0, rect.x, rect.y, 0,
            scratch, 0, 0, 0, 0, rect.w, rect.h, 1}); // RESOURCE_COPY_REGION
    }
    command(out, 5, 0, {0, 0}); // Unbind surfaces before retirement.
    command(out, 3, 8, {100}); command(out, 3, 8, {101});
    return message(6, out);
}
inline std::vector<uint8_t> overwriteReusedSource(uint32_t colorFormat = format) {
    std::vector<uint32_t> out;
    command(out, 1, 8, {100, resource, colorFormat, 0, 0});
    clear(out, 100, 1, 0, 1); // Magenta must NEVER appear in the snapshot.
    command(out, 5, 0, {0, 0});
    command(out, 3, 8, {100});
    return message(6, out);
}
}
