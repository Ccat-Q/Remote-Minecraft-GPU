#import "RGPUVirglProbe.h"
#include "RGPUVirglAPI.hpp"
#include "RGPUVTestSession.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <algorithm>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {
// The caller serializes diagnostics; no concurrent virgl/EGL initialization.
class ANGLEHost {
public:
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLConfig config = nullptr;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext root = EGL_NO_CONTEXT;
    std::vector<EGLContext> contexts;
    std::unique_ptr<rgpu::VTestSession> session;
    virgl_renderer_callbacks callbacks{}; // Outlives virgl_renderer_init.
    bool initialized = false;

    void initialize() {
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
        callbacks.version = 4;
        callbacks.get_egl_display = [](void* cookie) -> void* { return static_cast<ANGLEHost*>(cookie)->display; };
        callbacks.create_gl_context = [](void* cookie, int, virgl_renderer_gl_ctx_param* parameter) -> void* {
            auto& host = *static_cast<ANGLEHost*>(cookie);
            // Do not silently substitute a lower GLES version.
            const EGLint version[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, parameter->major_ver,
                EGL_CONTEXT_MINOR_VERSION_KHR, parameter->minor_ver, EGL_NONE};
            auto context = eglCreateContext(host.display, host.config,
                parameter->shared ? host.root : EGL_NO_CONTEXT, version);
            if (context == EGL_NO_CONTEXT) return nullptr;
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
            return eglMakeCurrent(host.display, surface, surface, context) ? 0 : -1;
        };
        callbacks.destroy_gl_context = [](void* cookie, void* context) {
            auto& host = *static_cast<ANGLEHost*>(cookie);
            if (eglGetCurrentContext() == context)
                eglMakeCurrent(host.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroyContext(host.display, context);
            host.contexts.erase(std::remove(host.contexts.begin(), host.contexts.end(), context), host.contexts.end());
            if (host.root == context) host.root = EGL_NO_CONTEXT;
        };
        callbacks.write_fence = [](void* cookie, uint32_t fence) {
            auto& host = *static_cast<ANGLEHost*>(cookie);
            if (host.session) host.session->fenceCompleted(fence);
        };
        // No USE_EGL: use caller contexts and borrowed ANGLE display (v4),
        // rather than initializing an unrelated internal platform winsys.
        if (virgl_renderer_init(this, VIRGL_RENDERER_USE_GLES, &callbacks))
            throw std::runtime_error("virglrenderer ANGLE initialization failed");
        initialized = true;
        session = std::make_unique<rgpu::VTestSession>();
    }
    ~ANGLEHost() {
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
void append(std::vector<uint8_t>& bytes, uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) bytes.push_back(uint8_t(value >> shift));
}
uint32_t word(const std::vector<uint8_t>& bytes, size_t at) {
    return uint32_t(bytes[at]) | uint32_t(bytes[at + 1]) << 8 |
        uint32_t(bytes[at + 2]) << 16 | uint32_t(bytes[at + 3]) << 24;
}
NSString* glName(GLenum name) {
    const auto value = glGetString(name);
    return value ? [NSString stringWithUTF8String:reinterpret_cast<const char*>(value)] : @"unavailable";
}
}
@implementation RGPUVirglProbe
+ (NSString *)runWithError:(NSError **)error
{
    try {
        ANGLEHost host;
        host.initialize();
        const char name[] = "RemoteGPU iOS native gate";
        std::vector<uint8_t> request;
        append(request, sizeof(name)); append(request, 8);
        request.insert(request.end(), name, name + sizeof(name));
        append(request, 0); append(request, 9);
        append(request, 0); append(request, 1);
        auto replies = host.session->feed(request.data(), request.size());
        if (replies.size() != 2 || !host.session->atCommandBoundary())
            throw std::runtime_error("Native vtest capset response missing");
        NSMutableString *report = [NSMutableString stringWithFormat:
            @"PASS: native vtest context + caps over ANGLE Metal\nHost GL: %@\nGLSL: %@\nRenderer: %@\n",
            glName(GL_VERSION), glName(GL_SHADING_LANGUAGE_VERSION), glName(GL_RENDERER)];
        for (size_t index = 0; index < replies.size(); ++index) {
            const auto& reply = replies[index];
            if (reply.size() < 8 || word(reply, 0) != reply.size() - 7 || word(reply, 4) != (index == 0 ? 2u : 1u))
                throw std::runtime_error("Invalid native vtest capset framing");
            NSData *caps = [NSData dataWithBytes:reply.data() + 8 length:reply.size() - 8];
            [report appendFormat:@"\nCapset %u: %lu bytes\nBase64: %@\n", word(reply, 4),
                (unsigned long)caps.length, [caps base64EncodedStringWithOptions:0]];
        }
        [report appendString:@"\nGuest OpenGL 3.2 Core is NOT yet verified. Ubuntu must create that context through this renderer. No remote display is connected.\n"];
        return report;
    } catch (const std::exception& failure) {
        if (error) *error = [NSError errorWithDomain:@"org.remotegpu.virgl" code:1
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()]}];
        return nil;
    }
}
@end
