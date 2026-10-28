// Linux GPU oracle only. Two real shared-context snapshots with simulated
// consumer retirement. CPU readbacks are test-only; NOT IOSurface/Metal proof.
#include "RGPUVirglAPI.hpp"
#include "RGPUVTestSession.hpp"
#include "RGPUVirglPattern.hpp"
#include "RGPUDisplaySlots.hpp"
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <chrono>
#include <thread>
#include <memory>
#include <cstdio>
#include <cstdlib>

static void check(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static void feed(rgpu::VTestSession& s, const std::vector<uint8_t>& bytes) { s.feed(bytes.data(), bytes.size()); }
static void wait(rgpu::VTestSession& s, uint32_t fence) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!s.isFenceComplete(fence)) {
        check(std::chrono::steady_clock::now() < end, "producer timeout");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
struct Snapshot {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext producer = EGL_NO_CONTEXT, context = EGL_NO_CONTEXT;
    GLuint fbos[2]{}, texture = 0;
    unsigned allocations = 0;
    void capture(const virgl_renderer_resource_info& info) {
        display = eglGetCurrentDisplay(); producer = eglGetCurrentContext();
        if (context == EGL_NO_CONTEXT) {
            EGLConfig config{}; EGLint count = 0;
            const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
            check(eglChooseConfig(display, attributes, &config, 1, &count) && count, "config missing");
            const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
            context = eglCreateContext(display, config, producer, version);
            check(context != EGL_NO_CONTEXT, "shared context missing");
            check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context), "bind new copy");
            glGenFramebuffers(2, fbos); glGenTextures(1, &texture);
            glBindTexture(GL_TEXTURE_2D, texture); glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 640, 360);
            ++allocations;
        } else check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context), "resume copy");
        check(glIsTexture(info.tex_id), "source not shared");
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbos[0]);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, info.tex_id, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbos[1]);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        check(glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE &&
            glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "FBO incomplete");
        glBlitFramebuffer(0, 0, 640, 360, 0, 0, 640, 360, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); glFlush();
        check(fence != nullptr, "copy fence missing");
        const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (true) {
            const auto status = glClientWaitSync(fence, 0, 0);
            check(status != GL_WAIT_FAILED && std::chrono::steady_clock::now() < end, "copy timeout/failure");
            if (status == GL_ALREADY_SIGNALED || status == GL_CONDITION_SATISFIED) break;
            check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT), "unbind poll");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context), "resume poll");
        }
        glDeleteSync(fence);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        check(glGetError() == GL_NO_ERROR, "copy GL error");
        check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, producer), "restore producer");
    }
    void verify(bool magenta) {
        check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context), "read snapshot context");
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbos[1]);
        std::vector<uint8_t> pixels(640 * 360 * 4);
        glReadPixels(0, 0, 640, 360, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data()); // TEST-ONLY.
        for (unsigned y = 0; y < 360; ++y) for (unsigned x = 0; x < 640; ++x) {
            int r = 5, g = 10, b = 20;
            if (x >= 32 && x < 192 && y >= 220 && y < 328) { r = 255; g = 0; b = 0; }
            if (x >= 440 && x < 580 && y >= 260 && y < 320) { r = 0; g = 255; b = 0; }
            if (x >= 60 && x < 160 && y >= 32 && y < 112) { r = 0; g = 0; b = 255; }
            if (x >= 350 && x < 570 && y >= 40 && y < 140) { r = 255; g = 255; b = 0; }
            if (magenta) { r = 255; g = 0; b = 255; }
            const auto i = (y * 640 + x) * 4;
            check(std::abs(int(pixels[i]) - r) <= 1 && std::abs(int(pixels[i+1]) - g) <= 1 &&
                std::abs(int(pixels[i+2]) - b) <= 1 && pixels[i+3] == 255, "snapshot content/format/orientation changed");
        }
        check(glGetError() == GL_NO_ERROR, "oracle GL error");
        check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, producer), "restore oracle producer");
    }
    ~Snapshot() {
        if (context == EGL_NO_CONTEXT) return;
        if (eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
            glFinish(); // TEST teardown only.
            glDeleteFramebuffers(2, fbos); glDeleteTextures(1, &texture);
        }
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, producer);
        eglDestroyContext(display, context);
    }
};
int main() {
    std::unique_ptr<rgpu::VTestSession> session;
    virgl_renderer_callbacks callbacks{}; callbacks.version = 1;
    callbacks.write_fence = [](void *cookie, uint32_t fence) {
        auto& s = *static_cast<std::unique_ptr<rgpu::VTestSession> *>(cookie);
        if (s) s->fenceCompleted(fence);
    };
    bool initialized = false;
    try {
        check(!virgl_renderer_init(&session, VIRGL_RENDERER_USE_EGL | VIRGL_RENDERER_USE_SURFACELESS |
            VIRGL_RENDERER_USE_GLES, &callbacks), "renderer init failed"); initialized = true;
        session = std::make_unique<rgpu::VTestSession>(1, false);
        feed(*session, rgpu::pattern::createContext());
        for (const uint32_t format : {67u, 1u}) {
            std::array<Snapshot, 2> slots;
            rgpu::DisplaySlots owner;
            feed(*session, rgpu::pattern::createResource(42, format));
            feed(*session, rgpu::pattern::createResource(43, format));
            auto capture = [&](uint64_t frame, bool magenta) {
                feed(*session, magenta ? rgpu::pattern::overwriteReusedSource(format) : rgpu::pattern::render(format));
                auto ticket = owner.begin(frame, 42, frame);
                session->retainForPresent(42); wait(*session, session->fenceForPresent());
                virgl_renderer_resource_info info{};
                check(!virgl_renderer_resource_get_info(42, &info), "resource info failed");
                owner.copying(ticket); slots[ticket.slot].capture(info);
                session->releaseFromPresent(42); owner.snapshot(ticket);
                return ticket;
            };
            auto first = capture(1, false); owner.presenting(first); // Deliberately defer consumer retirement.
            auto second = capture(2, true);
            check(owner.inUse() == 2 && !owner.canAdvance(), "missing two-slot backpressure");
            slots[0].verify(false); slots[1].verify(true);
            owner.complete(first); owner.presenting(second);
            // After freeing capacity, destroy/recreate source while the older
            // slot-1 snapshot is still owned by its simulated consumer.
            feed(*session, rgpu::pattern::message(3, {42}));
            feed(*session, rgpu::pattern::createResource(42, format));
            auto third = capture(3, false); // Reuses slot 0 only AFTER its retirement.
            check(third.slot == first.slot && third.generation != first.generation, "slot not reused with new generation");
            slots[0].verify(false); slots[1].verify(true);
            owner.complete(second); owner.presenting(third); owner.complete(third);
            check(slots[0].allocations == 1 && slots[1].allocations == 1 && owner.inUse() == 0, "slot allocation/recycling mismatch");
            feed(*session, rgpu::pattern::message(3, {42})); feed(*session, rgpu::pattern::message(3, {43}));
            std::printf("PASS LINUX ONLY: format=%u two real GPU snapshots remain distinct, held-consumer backpressure, source UNREF/recreate, two allocations and safe slot reuse; simulated consumer, NOT Metal\n", format);
        }
        check(session->commandCounts()[4] == 0, "unexpected wire GET");
        session.reset(); virgl_renderer_cleanup(&session);
        std::puts("TEST-ONLY snapshot readbacks=8; TRANSFER_GET=0; no iPhone/IOSurface/Metal evidence");
        return 0;
    } catch (const std::exception& failed) {
        std::fprintf(stderr, "FAIL double snapshot: %s EGL=0x%x GL=0x%x\n", failed.what(), eglGetError(), glGetError());
        session.reset(); if (initialized) virgl_renderer_cleanup(&session); return 1;
    }
}
