#include "RGPUVTestSession.hpp"
#include "RGPUVirglAPI.hpp"
#include <chrono>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>

static void word(std::vector<uint8_t>& data, uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) data.push_back(uint8_t(value >> shift));
}
static void send(rgpu::VTestSession& session, uint32_t id, std::initializer_list<uint32_t> args) {
    std::vector<uint8_t> data;
    word(data, uint32_t(args.size())); word(data, id);
    for (auto value : args) word(data, value);
    session.feed(data.data(), data.size());
}
static void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}

int main() {
    std::unique_ptr<rgpu::VTestSession> session;
    bool initialized = false;
    virgl_renderer_callbacks callbacks{};
    callbacks.version = 1;
    callbacks.write_fence = [](void* cookie, uint32_t fence) {
        auto& owner = *static_cast<std::unique_ptr<rgpu::VTestSession>*>(cookie);
        if (owner) owner->fenceCompleted(fence);
    };
    try {
        require(!virgl_renderer_init(&session, VIRGL_RENDERER_USE_EGL |
            VIRGL_RENDERER_USE_SURFACELESS | VIRGL_RENDERER_USE_GLES, &callbacks), "renderer init failed");
        initialized = true;
        session = std::make_unique<rgpu::VTestSession>();
        std::vector<uint8_t> create;
        word(create, 4); word(create, 8);
        create.insert(create.end(), {'t','e','s',0});
        session->feed(create.data(), create.size());
        // Pinned virgl_hw.h: PIPE_TEXTURE_2D=2, BGRA8_UNORM=1,
        // VIRGL_BIND_RENDER_TARGET=2. No renderer-internal header dependency.
        send(*session, 2, {42, 2, 1, 2, 4, 4, 1, 1, 0, 0});
        session->retainForPresent(42); session->retainForPresent(42);
        const auto fence = session->fenceForPresent();
        send(*session, 3, {42});
        virgl_renderer_resource_info info{};
        require(!virgl_renderer_resource_get_info(42, &info) && info.tex_id != 0,
                "UNREF destroyed retained renderer texture");
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (!session->isFenceComplete(fence)) {
            require(std::chrono::steady_clock::now() < deadline, "real renderer fence timeout");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        session->releaseFromPresent(42);
        require(!virgl_renderer_resource_get_info(42, &info), "first release destroyed shared display texture");
        session->releaseFromPresent(42);
        require(virgl_renderer_resource_get_info(42, &info) != 0, "last release leaked renderer texture");
        // A new generation may reuse the handle only after its final release.
        send(*session, 2, {42, 2, 1, 2, 4, 4, 1, 1, 0, 0});
        session->retainForPresent(42);
        send(*session, 3, {42});
        session.reset(); // Disconnect must release a retired, pinned texture.
        require(virgl_renderer_resource_get_info(42, &info) != 0, "disconnect leaked pinned texture");
        virgl_renderer_cleanup(&session);
        std::puts("PASS: real renderer texture survives UNREF, fixed fence completes, final release/disconnect destroys resource");
        return 0;
    } catch (const std::exception& failure) {
        std::fprintf(stderr, "FAIL: native renderer lifetime: %s\n", failure.what());
        session.reset();
        if (initialized) virgl_renderer_cleanup(&session);
        return 1;
    }
}
