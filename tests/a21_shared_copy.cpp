// CI-only Linux shared-EGL GPU snapshot oracle; NOT iPhone/IOSurface evidence.
#include "RGPUVirglAPI.hpp"
#include "RGPUVTestSession.hpp"
#include "RGPUVirglPattern.hpp"
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <chrono>
#include <memory>
#include <stdexcept>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <cstring>

static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static void feed(rgpu::VTestSession& session, const std::vector<uint8_t>& bytes) { session.feed(bytes.data(), bytes.size()); }
static void wait(rgpu::VTestSession& session, uint32_t fence) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!session.isFenceComplete(fence)) {
        require(std::chrono::steady_clock::now() < deadline, "Producer wait timed out");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
int main(int argc, char **argv) {
    const bool asyncPoll = argc == 2 && std::strcmp(argv[1], "--async-poll") == 0;
    if (argc > 1 && !asyncPoll) return 2;
    std::unique_ptr<rgpu::VTestSession> session;
    virgl_renderer_callbacks callbacks{};
    callbacks.version = 1;
    callbacks.write_fence = [](void *cookie, uint32_t fence) {
        auto& session = *static_cast<std::unique_ptr<rgpu::VTestSession> *>(cookie);
        if (session) session->fenceCompleted(fence);
    };
    EGLContext copy = EGL_NO_CONTEXT;
    EGLDisplay display = EGL_NO_DISPLAY;
    bool initialized = false;
    try {
        require(!virgl_renderer_init(&session, VIRGL_RENDERER_USE_EGL | VIRGL_RENDERER_USE_SURFACELESS |
            VIRGL_RENDERER_USE_GLES, &callbacks), "Renderer init failed");
        initialized = true;
        session = std::make_unique<rgpu::VTestSession>(1, false);
        feed(*session, rgpu::pattern::createContext());
        for (const uint32_t format : {67u, 1u}) {
            feed(*session, rgpu::pattern::createResource(42, format));
            feed(*session, rgpu::pattern::createResource(43, format));
            feed(*session, rgpu::pattern::render(format));
            session->retainForPresent(42);
            const auto fence = session->fenceForPresent();
            wait(*session, fence);
            const auto desc = session->validatePresentResource(42, 0, 0, 0, 0, 640, 360);
            virgl_renderer_resource_info info{};
            require(!virgl_renderer_resource_get_info(42, &info) && desc.format == format && !info.flags,
                "Resource info mismatch");
            display = eglGetCurrentDisplay();
            const auto producer = eglGetCurrentContext();
            EGLConfig config = nullptr; EGLint count = 0;
            const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
            require(eglChooseConfig(display, attributes, &config, 1, &count) && count, "Shared config unavailable");
            const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
            copy = eglCreateContext(display, config, producer, version);
            require(copy != EGL_NO_CONTEXT && eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, copy),
                "Shared copy context unavailable");
            require(glIsTexture(info.tex_id), "Actual VirGL texture not shared");
            GLuint fbos[2], snapshot;
            glGenFramebuffers(2, fbos); glGenTextures(1, &snapshot);
            glBindTexture(GL_TEXTURE_2D, snapshot);
            glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 640, 360);
            glBindFramebuffer(GL_READ_FRAMEBUFFER, fbos[0]);
            glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, info.tex_id, 0);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbos[1]);
            glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, snapshot, 0);
            require(glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE &&
                glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "Copy FBO incomplete");
            glBlitFramebuffer(0, 0, 640, 360, 0, 0, 640, 360, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            GLsync sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); glFlush();
            if (asyncPoll) require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT),
                "Unbind copy between independent ticks failed");
            auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
            GLenum status;
            unsigned polls = 0;
            do {
                if (asyncPoll) require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, copy),
                    "Restore shared context for zero-wait copy poll failed");
                status = glClientWaitSync(sync, 0, asyncPoll ? 0 : 5'000'000);
                ++polls;
                require(status != GL_WAIT_FAILED && std::chrono::steady_clock::now() < deadline, "Copy fence failed");
                if (asyncPoll && status == GL_TIMEOUT_EXPIRED) {
                    require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT), "Poll unbind failed");
                    std::this_thread::sleep_for(std::chrono::milliseconds(1)); // CI-only event-loop stand-in, NO packets.
                }
            } while (status != GL_ALREADY_SIGNALED && status != GL_CONDITION_SATISFIED);
            if (asyncPoll) std::printf("A3 Linux GPU oracle format=%u zero_wait_polls=%u; no network progress dependency; NOT iPhone evidence\n", format, polls);
            glDeleteSync(sync);
            require(glGetError() == GL_NO_ERROR, "GPU copy GL error");
            require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, producer), "Restore producer failed");
            // Reuse source immediately AFTER snapshot; a live view would now be magenta.
            feed(*session, rgpu::pattern::overwriteReusedSource(format));
            wait(*session, session->fenceForPresent());
            feed(*session, rgpu::pattern::message(3, {42}));
            session->releaseFromPresent(42);
            feed(*session, rgpu::pattern::message(3, {43}));
            require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, copy), "Snapshot read context failed");
            glBindFramebuffer(GL_READ_FRAMEBUFFER, fbos[1]);
            // TEST-ONLY readback; absent from the iOS display implementation.
            std::vector<uint8_t> pixels(640 * 360 * 4);
            glReadPixels(0, 0, 640, 360, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
            for (unsigned y = 0; y < 360; ++y) for (unsigned x = 0; x < 640; ++x) {
                int r = 5, g = 10, b = 20;
                if (x >= 32 && x < 192 && y >= 220 && y < 328) { r = 255; g = 0; b = 0; }
                if (x >= 440 && x < 580 && y >= 260 && y < 320) { r = 0; g = 255; b = 0; }
                if (x >= 60 && x < 160 && y >= 32 && y < 112) { r = 0; g = 0; b = 255; }
                if (x >= 350 && x < 570 && y >= 40 && y < 140) { r = 255; g = 255; b = 0; }
                auto at = (y * 640 + x) * 4;
                require(std::abs(int(pixels[at]) - r) <= 1 && std::abs(int(pixels[at+1]) - g) <= 1 &&
                    std::abs(int(pixels[at+2]) - b) <= 1 && pixels[at+3] == 255, "Snapshot changed or RGBA/BGRA/orientation mismatch");
            }
            glDeleteFramebuffers(2, fbos); glDeleteTextures(1, &snapshot);
            require(glGetError() == GL_NO_ERROR, "Snapshot cleanup GL error");
            require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, producer), "Cleanup producer failed");
            require(eglDestroyContext(display, copy), "Copy context cleanup failed"); copy = EGL_NO_CONTEXT;
            std::printf("PASS LINUX ONLY: source format=%u flags=%u shared texture + GPU blit + source overwrite/UNREF; every snapshot pixel unchanged\n", format, info.flags);
        }
        require(session->commandCounts()[4] == 0, "Unexpected wire readback");
        session.reset(); virgl_renderer_cleanup(&session);
        std::puts("TEST-ONLY snapshot readbacks=2; native TRANSFER_GET=0; IOSurface/Metal/iPhone NOT tested");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL A2.1 shared snapshot: %s EGL=0x%x GL=0x%x\n", error.what(), eglGetError(), glGetError());
        if (copy != EGL_NO_CONTEXT) eglDestroyContext(display, copy);
        session.reset(); if (initialized) virgl_renderer_cleanup(&session);
        return 1;
    }
}
