#pragma once
// TEST-ONLY receiver oracle. Never built into the phone or display transport.
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <chrono>
#include <stdexcept>
#include <vector>

inline std::vector<uint8_t> testSharedWindowSnapshot(const virgl_renderer_resource_info& info) {
    const auto display = eglGetCurrentDisplay(), producer = eglGetCurrentContext();
    const auto draw = eglGetCurrentSurface(EGL_DRAW), read = eglGetCurrentSurface(EGL_READ);
    EGLConfig config = nullptr; EGLint count = 0;
    const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    if (!eglChooseConfig(display, attributes, &config, 1, &count) || !count)
        throw std::runtime_error("shared window snapshot config failed");
    const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    const auto copy = eglCreateContext(display, config, producer, version);
    if (copy == EGL_NO_CONTEXT) throw std::runtime_error("shared window context failed");
    GLuint fbos[2]{}, texture = 0; GLsync sync = nullptr;
    auto cleanup = [&] {
        if (eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, copy)) {
            glFinish();
            if (sync) glDeleteSync(sync);
            glDeleteFramebuffers(2, fbos); glDeleteTextures(1, &texture);
        }
        eglMakeCurrent(display, draw, read, producer);
        eglDestroyContext(display, copy);
    };
    try {
        if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, copy) || !glIsTexture(info.tex_id))
            throw std::runtime_error("window source texture not shared");
        glGenFramebuffers(2, fbos); glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, info.width, info.height);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbos[0]);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, info.tex_id, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbos[1]);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        if (glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE ||
            glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            throw std::runtime_error("window snapshot FBO incomplete");
        // Same A1-window source-Y normalization as the iOS adapter.
        glBlitFramebuffer(0, info.height, info.width, 0, 0, 0, info.width, info.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); glFlush();
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        GLenum status;
        do {
            status = glClientWaitSync(sync, 0, 5'000'000);
            if (status == GL_WAIT_FAILED || std::chrono::steady_clock::now() >= deadline)
                throw std::runtime_error("window snapshot fence failed");
        } while (status != GL_ALREADY_SIGNALED && status != GL_CONDITION_SATISFIED);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbos[1]);
        std::vector<uint8_t> raw(info.width * info.height * 4), canonical(raw.size());
        glReadPixels(0, 0, info.width, info.height, GL_RGBA, GL_UNSIGNED_BYTE, raw.data()); // CI ONLY.
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("window snapshot GL error");
        // Compare what the display sees (high GL Y at screen top) with the
        // existing independent top-left A1 oracle; CPU conversion is test-only.
        for (unsigned y = 0; y < info.height; ++y) for (unsigned x = 0; x < info.width; ++x) {
            auto from = ((info.height - 1 - y) * info.width + x) * 4;
            auto to = (y * info.width + x) * 4;
            for (unsigned c = 0; c < 4; ++c)
                canonical[to + c] = raw[from + ((info.virgl_format == 1 && c < 3) ? 2 - c : c)];
        }
        cleanup();
        return canonical;
    } catch (...) { cleanup(); throw; }
}
