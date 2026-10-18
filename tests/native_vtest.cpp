#include "RGPUVTestSession.hpp"
#include "RGPUVirglAPI.hpp"
#include "RGPUCapabilities.hpp"
#include <string>
#include <sys/uio.h>
#include <cassert>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>

// Deterministic API double. The separate GL/QUIC gate uses the real renderer.
static int contexts = 0, resources = 0, writes = 0, destroys = 0;
extern "C" {
int virgl_renderer_context_create(uint32_t, uint32_t, const char*) { ++contexts; return 0; }
void virgl_renderer_context_destroy(uint32_t) { ++destroys; }
void virgl_renderer_get_cap_set(uint32_t, uint32_t* version, uint32_t* size) { *version = 1; *size = 4; }
void virgl_renderer_fill_caps(uint32_t, uint32_t, void* caps) { std::memset(caps, 0xa5, 4); }
int virgl_renderer_resource_create(virgl_renderer_resource_create_args*, iovec*, uint32_t) { ++resources; return 0; }
void virgl_renderer_resource_unref(uint32_t) { --resources; }
void virgl_renderer_ctx_attach_resource(int, int) {}
void virgl_renderer_ctx_detach_resource(int, int) {}
int virgl_renderer_transfer_read_iov(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, virgl_box*, uint64_t, iovec* iov, int) {
    std::memset(iov->iov_base, 0x7f, iov->iov_len); return 0;
}
int virgl_renderer_transfer_write_iov(uint32_t, uint32_t, int, uint32_t, uint32_t, virgl_box*, uint64_t, iovec* iov, unsigned int) {
    assert(iov->iov_len == 3 && static_cast<uint8_t*>(iov->iov_base)[2] == 0xcc); ++writes; return 0;
}
int virgl_renderer_submit_cmd(void*, int, int) { return 0; }
int virgl_renderer_create_fence(int, uint32_t) { return 0; }
void virgl_renderer_poll() {}
}
static void word(std::vector<uint8_t>& data, uint32_t value) {
    for (int i = 0; i < 4; ++i) data.push_back(uint8_t(value >> (8 * i)));
}
static void command(std::vector<uint8_t>& data, uint32_t id, const std::vector<uint32_t>& args = {}) {
    word(data, uint32_t(args.size())); word(data, id);
    for (auto arg : args) word(data, arg);
}
static std::vector<uint8_t> create() {
    std::vector<uint8_t> data;
    word(data, 4); word(data, 8);
    data.insert(data.end(), {'t', 'e', 's', 0});
    return data;
}
static void rejects(std::vector<uint8_t> data) {
    rgpu::VTestSession session;
    bool rejected = false;
    try { session.feed(data.data(), data.size()); } catch (const std::runtime_error&) { rejected = true; }
    assert(rejected);
    try { session.feed(nullptr, 0); assert(false); } catch (const std::runtime_error&) {}
}
int main() {
    {
        std::vector<uint8_t> caps(308);
        caps[264] = 130; caps[280] = 8; caps[284] = 8; caps[296] = 15;
        auto summary = rgpu::summarizeCaps(1, caps.data(), caps.size());
        assert(summary.glslLevel == 130 && !summary.meetsGlslThreshold());
        assert(summary.renderTargets == 8 && summary.samples == 8 && summary.uniformBlocks == 15);
        caps[264] = 150;
        assert(rgpu::summarizeCaps(2, caps.data(), caps.size()).meetsGlslThreshold());
        try { rgpu::summarizeCaps(1, caps.data(), 307); assert(false); } catch (const std::runtime_error&) {}
        try { rgpu::summarizeCaps(3, caps.data(), caps.size()); assert(false); } catch (const std::runtime_error&) {}
    }
    {
        auto data = create();
        command(data, 9); command(data, 1);
        command(data, 2, {1, 0, 0, 0, 1, 1, 1, 1, 0, 0});
        word(data, 12); word(data, 5);
        for (auto value : {1u, 0u, 0u, 0u, 0u, 0u, 0u, 3u, 1u, 1u, 3u}) word(data, value);
        data.insert(data.end(), {0xaa, 0xbb, 0xcc});
        command(data, 4, {1, 0, 0, 0, 0, 0, 0, 3, 1, 1, 3});
        command(data, 6, {0}); command(data, 7, {0, 0});
        rgpu::VTestSession session;
        std::vector<std::vector<uint8_t>> replies;
        for (auto byte : data) {
            for (auto reply : session.feed(&byte, 1)) replies.push_back(reply);
        }
        assert(contexts == 1 && resources == 1 && writes == 1);
        assert(session.atCommandBoundary() && replies.size() == 4);
        assert(replies[0] == std::vector<uint8_t>({5,0,0,0,2,0,0,0,0xa5,0xa5,0xa5,0xa5}));
        assert(replies[1][4] == 1 && replies[2] == std::vector<uint8_t>({0x7f,0x7f,0x7f}));
        assert(replies[3][8] == 1 && session.busy());
        session.fenceCompleted(1); assert(!session.busy());
        auto unref = std::vector<uint8_t>(); command(unref, 3, {1});
        session.feed(unref.data(), unref.size()); assert(resources == 0);
    }
    assert(destroys == 1);
    { auto data = create(); command(data, 1); command(data, 9);
      command(data, 2, {1, 0, 0, 0, 1, 1, 1, 1, 0, 0});
      rgpu::VTestSession session; assert(session.feed(data.data(), data.size()).size() == 2);
      assert(resources == 1); }
    assert(resources == 0); // disconnect releases resources without UNREF
    std::vector<uint8_t> bad; command(bad, 12); rejects(bad);
    bad.clear(); command(bad, 1); rejects(bad);
    bad.clear(); word(bad, 0xffffffffu); word(bad, 6); rejects(bad);
    bad = create(); command(bad, 5, {1}); rejects(bad);
    bad = create(); command(bad, 3, {99}); rejects(bad);
    bad.clear(); word(bad, 1000000); word(bad, 1); rejects(bad);
    bad = create();
    command(bad, 2, {1, 0, 0, 0, 1, 1, 1, 1, 0, 0});
    command(bad, 2, {1, 0, 0, 0, 1, 1, 1, 1, 0, 0});
    rejects(bad); assert(resources == 0);
    {
        rgpu::VTestSession session;
        auto data = create(); command(data, 2, {42, 0, 0, 0, 1, 1, 1, 1, 0, 0});
        command(data, 6, {0});
        session.feed(data.data(), data.size());
        const auto frameFence = session.fenceForPresent();
        assert(frameFence == 2 && !session.isFenceComplete(frameFence));
        session.retainForPresent(42); session.retainForPresent(42);
        data.clear(); command(data, 6, {0}); command(data, 3, {42});
        session.feed(data.data(), data.size());
        assert(resources == 1); // UNREF cannot destroy a pending display resource
        session.fenceCompleted(frameFence);
        assert(session.isFenceComplete(frameFence) && session.busy());
        session.releaseFromPresent(42); assert(resources == 1);
        session.releaseFromPresent(42); assert(resources == 0);
        try { session.releaseFromPresent(42); assert(false); } catch (const std::runtime_error&) {}
    }
    {
        rgpu::VTestSession session;
        auto data = create(); command(data, 2, {43, 0, 0, 0, 1, 1, 1, 1, 0, 0});
        session.feed(data.data(), data.size()); session.retainForPresent(43);
        data.clear(); command(data, 3, {43}); session.feed(data.data(), data.size());
        try { session.retainForPresent(43); assert(false); } catch (const std::runtime_error&) {}
        data.clear(); command(data, 2, {43, 0, 0, 0, 1, 1, 1, 1, 0, 0});
        try { session.feed(data.data(), data.size()); assert(false); } catch (const std::runtime_error&) {}
        // A reconnect/disconnect releases pinned resources even after failure.
    }
    assert(resources == 0);
    {
        rgpu::VTestSession session(1, false);
        auto data = create(); command(data, 2, {9, 0, 0, 0, 1, 1, 1, 1, 0, 0});
        command(data, 4, {9, 0, 0, 0, 0, 0, 0, 3, 1, 1, 3});
        try { session.feed(data.data(), data.size()); assert(false); }
        catch (const std::runtime_error& failure) {
            assert(std::string(failure.what()).find("TRANSFER_GET disabled") != std::string::npos);
        }
    }
    assert(resources == 0);
    std::cout << "PASS: fragmented/coalesced legacy vtest, caps bytes, unpadded PUT, raw GET, fences, fail-closed\n";
    {
        rgpu::VTestSession session(1, false);
        auto data = create(); command(data, 2, {42, 2, 1, 10, 64, 64, 1, 1, 0, 0});
        session.feed(data.data(), data.size());
        auto desc = session.validatePresentResource(42, 0, 0, 0, 0, 64, 64);
        assert(desc.target == 2 && desc.format == 1 && desc.samples == 0);
        for (auto id : {uint64_t(0), uint64_t(99), uint64_t(1) << 32}) {
            try { session.validatePresentResource(id, 0, 0, 0, 0, 64, 64); assert(false); }
            catch (const std::runtime_error&) {}
        }
        try { session.validatePresentResource(42, 1, 0, 0, 0, 64, 64); assert(false); } catch (const std::runtime_error&) {}
        try { session.validatePresentResource(42, 0, 0, 0, 0, 63, 64); assert(false); } catch (const std::runtime_error&) {}
        data.clear(); command(data, 2, {43, 2, 1, 10, 64, 64, 1, 1, 0, 4});
        session.feed(data.data(), data.size());
        try { session.validatePresentResource(43, 0, 0, 0, 0, 64, 64); assert(false); } catch (const std::runtime_error&) {}
        data.clear(); word(data, 1); // Fragmented command: PRESENT must not split it.
        session.feed(data.data(), data.size());
        try { session.validatePresentResource(42, 0, 0, 0, 0, 64, 64); assert(false); } catch (const std::runtime_error&) {}
    }
    {
        bool cancelled = false;
        rgpu::VTestSession session;
        session.setCancellationCheck([&] { return cancelled; });
        auto data = create(); command(data, 2, {42, 2, 1, 10, 64, 64, 1, 1, 0, 0});
        session.feed(data.data(), data.size());
        session.retainForPresent(42);
        cancelled = true;
        try { session.feed(nullptr, 0); assert(false); } catch (const std::runtime_error&) {}
        assert(session.commandCounts()[2] == 1 && session.commandCounts()[4] == 0);
    }
    assert(resources == 0); // Cancellation releases pinned resources on teardown.
    std::cout << "PASS: A2.1 resource metadata/profile/boundary rejection and cancelled-session cleanup\n";
}
