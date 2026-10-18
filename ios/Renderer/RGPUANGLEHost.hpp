#pragma once
#import <Foundation/Foundation.h>
#include "RGPUVirglAPI.hpp"
#include "RGPUVTestSession.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <algorithm>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <vector>

// The caller serializes diagnostics; no concurrent virgl/EGL initialization.
class ANGLEHost {
public:
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLConfig config = nullptr;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext root = EGL_NO_CONTEXT;
    EGLContext suspendedContext = EGL_NO_CONTEXT;
    std::vector<EGLContext> contexts;
    std::unique_ptr<rgpu::VTestSession> session;
    virgl_renderer_callbacks callbacks{}; // Outlives virgl_renderer_init.
    bool initialized = false;
    int lastMajor = 0, lastMinor = 0;
    EGLint lastContextError = EGL_SUCCESS;
    NSString *versionAttempts = @"";

    void probeGlesVersions() {
        const char *apis = eglQueryString(display, EGL_CLIENT_APIS);
        NSMutableString *result = [NSMutableString stringWithFormat:@"EGL client APIs: %s\n", apis ?: "unavailable"];
        for (int requestedMinor : {2, 1, 0}) {
            const EGLint version[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
                EGL_CONTEXT_MINOR_VERSION_KHR, requestedMinor, EGL_NONE};
            auto candidate = eglCreateContext(display, config, EGL_NO_CONTEXT, version);
            if (candidate == EGL_NO_CONTEXT) {
                [result appendFormat:@"GLES 3.%d request: rejected, EGL 0x%x\n", requestedMinor, static_cast<unsigned>(eglGetError())];
                continue;
            }
            if (eglMakeCurrent(display, surface, surface, candidate)) {
                GLint actualMajor = 0, actualMinor = 0;
                glGetIntegerv(GL_MAJOR_VERSION, &actualMajor);
                glGetIntegerv(GL_MINOR_VERSION, &actualMinor);
                [result appendFormat:@"GLES 3.%d request: actual %d.%d (%@)\n", requestedMinor,
                    actualMajor, actualMinor, (actualMajor > 3 || (actualMajor == 3 && actualMinor >= requestedMinor)) ?
                        @"version request satisfied" : @"unexpected downgrade; do not accept as capability proof"];
            } else {
                [result appendFormat:@"GLES 3.%d make-current: failed, EGL 0x%x\n", requestedMinor, static_cast<unsigned>(eglGetError())];
            }
            const auto unbound = eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroyContext(display, candidate);
            if (!unbound) throw std::runtime_error("Cannot unbind temporary GLES version probe");
        }
        versionAttempts = result;
    }

    void initialize(bool allowReadbacks = true, bool probeVersions = false) {
        auto platform = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
        if (!platform) throw std::runtime_error("ANGLE platform API unavailable");
        const EGLint attributes[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
        display = platform(EGL_PLATFORM_ANGLE_ANGLE, nullptr, attributes);
        if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr) || !eglBindAPI(EGL_OPENGL_ES_API))
            throw std::runtime_error("ANGLE Metal display initialization failed");
        const EGLint configuration[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT | EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
        EGLint count = 0;
        if (!eglChooseConfig(display, configuration, &config, 1, &count) || count != 1)
            throw std::runtime_error("No ANGLE GLES configuration");
        const EGLint dimensions[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        surface = eglCreatePbufferSurface(display, config, dimensions);
        if (surface == EGL_NO_SURFACE) throw std::runtime_error("ANGLE control surface allocation failed");
        // Run only in the one-shot diagnostic, before virgl owns/caches GL
        // state. Never switch arbitrary contexts during a live vtest session.
        if (probeVersions) probeGlesVersions();
        callbacks.version = 4;
        callbacks.get_egl_display = [](void* cookie) -> void* { return static_cast<ANGLEHost*>(cookie)->display; };
        callbacks.create_gl_context = [](void* cookie, int, virgl_renderer_gl_ctx_param* parameter) -> void* {
            auto& host = *static_cast<ANGLEHost*>(cookie);
            host.lastMajor = parameter->major_ver;
            host.lastMinor = parameter->minor_ver;
            // Do not silently substitute a lower GLES version.
            const EGLint version[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, parameter->major_ver,
                EGL_CONTEXT_MINOR_VERSION_KHR, parameter->minor_ver, EGL_NONE};
            auto context = eglCreateContext(host.display, host.config,
                parameter->shared ? host.root : EGL_NO_CONTEXT, version);
            if (context == EGL_NO_CONTEXT) {
                host.lastContextError = eglGetError();
                return nullptr;
            }
            host.lastContextError = EGL_SUCCESS;
            if (host.root == EGL_NO_CONTEXT) host.root = context;
            try { host.contexts.push_back(context); }
            catch (...) {
                if (host.root == context) host.root = EGL_NO_CONTEXT;
                eglDestroyContext(host.display, context);
                return nullptr;
            }
            return context;
        };
        callbacks.make_current = [](void* cookie, int, void* context) -> int {
            auto& host = *static_cast<ANGLEHost*>(cookie);
            const auto surface = context ? host.surface : EGL_NO_SURFACE;
            if (eglMakeCurrent(host.display, surface, surface, context)) {
                host.suspendedContext = context;
                return 0;
            }
            host.lastContextError = eglGetError();
            return -1;
        };
        callbacks.destroy_gl_context = [](void* cookie, void* context) {
            auto& host = *static_cast<ANGLEHost*>(cookie);
            if (eglGetCurrentContext() == context)
                eglMakeCurrent(host.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroyContext(host.display, context);
            if (host.suspendedContext == context) host.suspendedContext = EGL_NO_CONTEXT;
            host.contexts.erase(std::remove(host.contexts.begin(), host.contexts.end(), context), host.contexts.end());
            if (host.root == context) host.root = EGL_NO_CONTEXT;
        };
        callbacks.write_fence = [](void* cookie, uint32_t fence) {
            auto& host = *static_cast<ANGLEHost*>(cookie);
            if (host.session) host.session->fenceCompleted(fence);
        };
        // No USE_EGL: use caller contexts and borrowed ANGLE display (v4),
        // rather than initializing an unrelated internal platform winsys.
        if (virgl_renderer_init(this, VIRGL_RENDERER_USE_GLES, &callbacks)) {
            char message[256];
            std::snprintf(message, sizeof(message),
                "virglrenderer ANGLE initialization failed; last context attempt %d.%d, EGL error 0x%x",
                lastMajor, lastMinor, static_cast<unsigned>(lastContextError));
            throw std::runtime_error(message);
        }
        initialized = true;
        session = std::make_unique<rgpu::VTestSession>(1, allowReadbacks);
    }
    void resume() {
        const auto target = suspendedContext == EGL_NO_CONTEXT ? EGL_NO_SURFACE : surface;
        if (!eglBindAPI(EGL_OPENGL_ES_API) ||
            !eglMakeCurrent(display, target, target, suspendedContext))
            throw std::runtime_error("Cannot restore native EGL context on renderer queue");
    }
    void suspend() {
        if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT))
            throw std::runtime_error("Cannot unbind native EGL context from renderer queue");
    }
    ~ANGLEHost() {
        // Dispatch queues serialize work but do not guarantee a fixed OS
        // thread. Restore EGL before deleting session-owned GL resources.
        if (initialized) {
            try { resume(); } catch (...) {}
        }
        session.reset();
        if (initialized) virgl_renderer_cleanup(this);
        if (display != EGL_NO_DISPLAY) {
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            for (auto context : contexts) eglDestroyContext(display, context);
            if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
            eglTerminate(display);
        }
    }
};
