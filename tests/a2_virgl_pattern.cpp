// Linux software-renderer oracle ONLY, not iPhone GPU/IOSurface acceptance.
// CPU readback exists solely in this CI executable, not the iOS adapter.
#include "RGPUVirglAPI.hpp"
#include "RGPUVTestSession.hpp"
#include "RGPUVirglPattern.hpp"
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <stdexcept>
#include <thread>
#include <sys/uio.h>

static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static void feed(rgpu::VTestSession& session, const std::vector<uint8_t>& bytes) {
    require(session.feed(bytes.data(), bytes.size()).empty(), "Unexpected decoder reply");
    require(session.atCommandBoundary(), "Incomplete fixture");
}
static bool matches(const std::vector<uint8_t>& pixels) {
    // Independent oracle; don't derive expected rectangles from fixture data.
    for (unsigned y = 0; y < 360; ++y) for (unsigned x = 0; x < 640; ++x) {
        std::array<int, 4> expected = {5, 10, 20, 255};
        if (x >= 32 && x < 192 && y >= 220 && y < 328) expected = {255, 0, 0, 255};
        if (x >= 440 && x < 580 && y >= 260 && y < 320) expected = {0, 255, 0, 255};
        if (x >= 60 && x < 160 && y >= 32 && y < 112) expected = {0, 0, 255, 255};
        if (x >= 350 && x < 570 && y >= 40 && y < 140) expected = {255, 255, 0, 255};
        for (unsigned c = 0; c < 4; ++c)
            if (std::abs(int(pixels[(y * 640 + x) * 4 + c]) - expected[c]) > 1) return false;
    }
    return true;
}
int main() {
    std::unique_ptr<rgpu::VTestSession> session;
    virgl_renderer_callbacks callbacks{};
    callbacks.version = 1;
    callbacks.write_fence = [](void *cookie, uint32_t fence) {
        auto& session = *static_cast<std::unique_ptr<rgpu::VTestSession> *>(cookie);
        if (session) session->fenceCompleted(fence);
    };
    bool initialized = false;
    try {
        require(!virgl_renderer_init(&session, VIRGL_RENDERER_USE_EGL |
            VIRGL_RENDERER_USE_SURFACELESS | VIRGL_RENDERER_USE_GLES, &callbacks), "Renderer init failed");
        initialized = true;
        session = std::make_unique<rgpu::VTestSession>(1, false);
        feed(*session, rgpu::pattern::createContext());
        feed(*session, rgpu::pattern::createResource(rgpu::pattern::resource));
        feed(*session, rgpu::pattern::createResource(rgpu::pattern::scratch));
        feed(*session, rgpu::pattern::render());
        const auto fence = session->fenceForPresent();
        session->retainForPresent(rgpu::pattern::resource);
        feed(*session, rgpu::pattern::message(3, {rgpu::pattern::resource}));
        feed(*session, rgpu::pattern::message(3, {rgpu::pattern::scratch}));
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (!session->isFenceComplete(fence)) {
            require(std::chrono::steady_clock::now() < deadline, "Producer timeout");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        virgl_renderer_resource_info info{};
        require(!virgl_renderer_resource_get_info(rgpu::pattern::resource, &info) && info.tex_id &&
            info.width == 640 && info.height == 360 && info.virgl_format == 67 && !info.flags,
            "Pinned texture metadata incorrect");
        std::vector<uint8_t> pixels(640 * 360 * 4);
        iovec destination{pixels.data(), pixels.size()};
        virgl_box box{0, 0, 0, 640, 360, 1};
        require(!virgl_renderer_transfer_read_iov(rgpu::pattern::resource, 0, 0, 640 * 4,
            0, &box, 0, &destination, 1), "TEST-ONLY readback failed");
        require(matches(pixels), "VirGL GPU asymmetric pattern pixels differ from independent oracle");
        pixels[(250 * 640 + 80) * 4] = 0;
        require(!matches(pixels), "Oracle did not reject corrupt red rectangle");
        session->releaseFromPresent(rgpu::pattern::resource);
        require(virgl_renderer_resource_get_info(rgpu::pattern::resource, &info) != 0, "Source leaked after release");
        feed(*session, rgpu::pattern::createResource(rgpu::pattern::resource));
        feed(*session, rgpu::pattern::message(3, {rgpu::pattern::resource}));
        session.reset();
        virgl_renderer_cleanup(&session);
        std::puts("PASS: A2 VirGL GPU pattern 640x360 exact pixels; corruption rejected; producer fence + pinned UNREF + handle reuse");
        std::puts("TEST-ONLY receiver readback=1; vtest TRANSFER_GET=0, TRANSFER_PUT=0; NOT iPhone GPU acceptance");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL A2 VirGL fixture: %s\n", error.what());
        session.reset();
        if (initialized) virgl_renderer_cleanup(&session);
        return 1;
    }
}
