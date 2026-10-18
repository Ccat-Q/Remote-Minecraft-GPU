#pragma once
// CI ONLY: CPU oracle on the receiver, never a vtest TRANSFER_GET or display.
#include "RGPUVTestSession.hpp"
#include "RGPUVirglAPI.hpp"
#include "shared-scanout-test.hpp"
#include <cstdlib>
#include <sys/uio.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <thread>
#include <vector>

namespace rgpu_test {
inline uint64_t be(const uint8_t* p, unsigned n) {
    uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i) v = (v << 8) | p[i];
    return v;
}
inline void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
class FrameVerifier {
    unsigned expected_, verified_ = 0, readbacks_ = 0;
    uint64_t lastPresent_ = 0;
    uint32_t held_ = 0;
    bool holdVerified_ = false;
    std::chrono::steady_clock::time_point lastTime_;

    std::vector<uint8_t> readResource(uint32_t resource, virgl_renderer_resource_info& info) {
        require(!virgl_renderer_resource_get_info(resource, &info), "oracle resource missing");
        require(info.width == 64 && info.height == 64 && info.depth == 1 && info.tex_id,
                "oracle unsupported resource dimensions");
        // Pinned virgl_hw.h: BGRA8/BGRX8=1/2, RGBA8=67. No iOS ABI changes.
        require(info.virgl_format == 1 || info.virgl_format == 2 || info.virgl_format == 67,
                "oracle unsupported resource format");
        if (std::getenv("REMOTEGPU_TEST_SHARED_SCANOUT")) {
            require(info.flags == 0 && info.virgl_format == 1, "A1 shared scanout profile changed");
            auto pixels = testSharedWindowSnapshot(info);
            std::fprintf(stderr, "TEST_GPU_SCANOUT resource=%u shared_context=1 source_y_normalized=1 fence_complete=1\n", resource);
            return pixels;
        }
        std::vector<uint8_t> pixels(64 * 64 * 4);
        iovec iov{pixels.data(), pixels.size()};
        virgl_box box{0, 0, 0, 64, 64, 1};
        require(!virgl_renderer_transfer_read_iov(resource, 1, 0, 64 * 4, 0, &box, 0, &iov, 1),
                "test-side resource read failed");
        ++readbacks_;
        return pixels;
    }
    bool matches(const std::vector<uint8_t>& pixels, const virgl_renderer_resource_info& info,
                 unsigned frame, unsigned& checked) const {
        const double dx = (int(frame % 5) - 2) * 0.16;
        const double dy = (int(frame / 5 % 3) - 1) * 0.12;
        const int tint[] = {40 + int(frame * 37 % 180), 50 + int(frame * 67 % 170), 60 + int(frame * 97 % 160)};
        const int background[] = {8, 16, 24};
        checked = 0;
        unsigned wrong = 0, insideCount = 0;
        for (unsigned row = 0; row < 64; ++row) for (unsigned col = 0; col < 64; ++col) {
            double x = (col + 0.5) / 32.0 - 1 - dx;
            // transfer_read_iov returns Gallium resource rows (top-left for
            // the window target), NOT raw glReadPixels rows. The renderer
            // already handles storage inversion; flags describe GL storage.
            double y = 1 - (row + 0.5) / 32.0;
            y -= dy;
            // Independent CPU half-plane reference. Exclude ~one pixel at edges.
            double e0 = y + 0.4;
            double e1 = (-0.8 * (x - 0.3) - 0.3 * (y + 0.4)) / std::sqrt(0.73);
            double e2 = (0.8 * x - 0.3 * (y - 0.4)) / std::sqrt(0.73);
            if (std::fabs(e0) < 0.035 || std::fabs(e1) < 0.035 || std::fabs(e2) < 0.035) continue;
            bool inside = e0 > 0 && e1 > 0 && e2 > 0;
            if (inside) ++insideCount;
            const int* expected = inside ? tint : background;
            const auto* p = pixels.data() + (row * 64 + col) * 4;
            bool bad = false;
            for (int c = 0; c < 3; ++c) {
                int channel = info.virgl_format == 67 ? c : 2 - c;
                if (std::abs(int(p[channel]) - expected[c]) > 2) bad = true;
            }
            ++checked;
            if (bad) ++wrong;
        }
        return checked > 3000 && insideCount > 100 && wrong == 0;
    }
public:
    explicit FrameVerifier(unsigned expected) : expected_(expected) {}
    void verify(const uint8_t* present, rgpu::VTestSession& session) {
        const auto frame = be(present, 8), resource = be(present + 8, 8);
        require(frame == lastPresent_ + 1 && resource && resource <= std::numeric_limits<uint32_t>::max(),
                "oracle PRESENT order/handle mismatch");
        lastPresent_ = frame;
        require(be(present + 24, 4) == 0 && be(present + 28, 4) == 0 &&
                be(present + 32, 4) == 0 && be(present + 36, 4) == 0 &&
                be(present + 40, 4) == 64 && be(present + 44, 4) == 64,
                "oracle unsupported PRESENT subresource");
        require(session.atCommandBoundary(), "PRESENT inside partial vtest command");
        const auto handle = uint32_t(resource);
        session.retainForPresent(handle);
        try {
            const auto fence = session.fenceForPresent();
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
            while (!session.isFenceComplete(fence)) {
                require(std::chrono::steady_clock::now() < deadline, "oracle GPU fence timeout");
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            virgl_renderer_resource_info info{};
            auto pixels = readResource(handle, info);
            unsigned checked = 0;
            if (!matches(pixels, info, verified_, checked)) {
                if (frame == 1 && verified_ == 0) {
                    std::fprintf(stderr, "ORACLE_INIT_PRESENT frame=1 skipped=1\n");
                    session.releaseFromPresent(handle);
                    return;
                }
                std::fprintf(stderr, "ORACLE_MISMATCH app_frame=%u present=%llu format=%u flags=%u checked=%u\n",
                    verified_, (unsigned long long)frame, info.virgl_format, info.flags, checked);
                unsigned minx = 64, miny = 64, maxx = 0, maxy = 0, changed = 0;
                for (unsigned row = 0; row < 64; ++row) for (unsigned col = 0; col < 64; ++col) {
                    const auto* p = pixels.data() + (row * 64 + col) * 4;
                    int r = p[info.virgl_format == 67 ? 0 : 2], g = p[1], b = p[info.virgl_format == 67 ? 2 : 0];
                    if (std::abs(r - 8) > 2 || std::abs(g - 16) > 2 || std::abs(b - 24) > 2) {
                        ++changed;
                        minx = std::min(minx, col); maxx = std::max(maxx, col);
                        miny = std::min(miny, row); maxy = std::max(maxy, row);
                    }
                }
                std::fprintf(stderr, "ORACLE_PIXELS changed=%u bounds=%u,%u..%u,%u raw_center=%u,%u,%u,%u raw_corner=%u,%u,%u,%u\n",
                    changed, minx, miny, maxx, maxy,
                    pixels[8320], pixels[8321], pixels[8322], pixels[8323], pixels[0], pixels[1], pixels[2], pixels[3]);
                throw std::runtime_error("receiver pixel reference mismatch");
            }
            require(verified_ < expected_, "unexpected extra application PRESENT");
            const auto desc = session.validatePresentResource(handle, 0, 0, 0, 0, 64, 64);
            std::fprintf(stderr, "ORACLE_FRAME app_frame=%u present=%llu resource=%u pixels=%u fence=%u format=%u flags=%u target=%u samples=%u array=%u last_level=%u\n",
                verified_, (unsigned long long)frame, handle, checked, fence, info.virgl_format, info.flags,
                desc.target, desc.samples, desc.arraySize, desc.lastLevel);
            ++verified_;
            if (verified_ == expected_) {
                held_ = handle;
                lastTime_ = std::chrono::steady_clock::now();
            } else session.releaseFromPresent(handle);
        } catch (...) { session.releaseFromPresent(handle); throw; }
    }
    void pollHold(rgpu::VTestSession& session) {
        if (!held_ || holdVerified_ || std::chrono::steady_clock::now() - lastTime_ < std::chrono::milliseconds(400)) return;
        virgl_renderer_resource_info info{};
        auto pixels = readResource(held_, info);
        unsigned checked = 0;
        require(matches(pixels, info, expected_ - 1, checked), "last frame changed during hold");
        session.releaseFromPresent(held_);
        held_ = 0;
        holdVerified_ = true;
        std::fprintf(stderr, "ORACLE_HOLD_PASS app_frame=%u idle_ms=400\n", expected_ - 1);
    }
    void finish(rgpu::VTestSession& session) {
        if (held_) { session.releaseFromPresent(held_); held_ = 0; }
        require(verified_ == expected_ && holdVerified_, "incomplete frames or missing final hold");
        std::fprintf(stderr, "ORACLE_PASS frames=%u test_side_readbacks=%u wire_TRANSFER_GET=not_used\n", verified_, readbacks_);
    }
};
}
