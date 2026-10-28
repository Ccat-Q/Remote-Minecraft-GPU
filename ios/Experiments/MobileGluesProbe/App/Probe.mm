#import "Probe.h"
#include "ProviderPolicy.hpp"
#import <UIKit/UIKit.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h> // pinned candidate provides the superset header; no ES3.2 request
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sys/utsname.h>
#include <atomic>
#include <array>
#include <cmath>
#include <stdexcept>
#include <string>
#include <thread>

namespace {
std::atomic<bool> ran{false};
void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}
std::string owner(void *address, const char *entry = "unnamed pointer") {
    Dl_info info{};
    if (!address) throw std::runtime_error(std::string(entry) + ": NULL symbol/proc pointer");
    if (!dladdr(address, &info) || !info.dli_fname || !info.dli_fbase)
        throw std::runtime_error(std::string(entry) + ": non-null pointer has no dladdr provider identity");
    return info.dli_fname;
}
void *load(NSString *name) {
    NSString *path = [[NSBundle.mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:[name stringByAppendingString:@".framework"]]
        stringByAppendingPathComponent:name];
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!handle) throw std::runtime_error(std::string("dlopen ") + name.UTF8String + ": " + dlerror());
    return handle; // intentionally process-resident; MobileGlues TLS/statics forbid unsafe dlclose
}
template<class T> T symbol(void *handle, const char *name, const char *expected) {
    dlerror(); // Distinguish a missing symbol from a dladdr failure.
    void *p = dlsym(handle, name);
    const char *error = dlerror();
    if (!p || error) throw std::runtime_error(std::string("dlsym ") + name + ": " + (error ?: "NULL address"));
    std::string actual = owner(p, name);
    if (actual.find(expected) == std::string::npos)
        throw std::runtime_error(std::string(name) + ": unexpected provider " + actual);
    return reinterpret_cast<T>(p);
}

struct Frontend {
    void *library;
#define EGL_ENTRY(name) decltype(&::name) name = symbol<decltype(&::name)>(library, #name, "/MobileGluesProbe.framework/")
    EGL_ENTRY(eglGetError); EGL_ENTRY(eglInitialize); EGL_ENTRY(eglBindAPI);
    EGL_ENTRY(eglChooseConfig); EGL_ENTRY(eglCreatePbufferSurface); EGL_ENTRY(eglCreateContext);
    EGL_ENTRY(eglMakeCurrent); EGL_ENTRY(eglGetCurrentContext); EGL_ENTRY(eglGetCurrentDisplay);
    EGL_ENTRY(eglQueryAPI); EGL_ENTRY(eglQueryContext); EGL_ENTRY(eglDestroyContext);
    EGL_ENTRY(eglDestroySurface); EGL_ENTRY(eglTerminate); EGL_ENTRY(eglGetProcAddress);
    EGL_ENTRY(eglReleaseThread);
#undef EGL_ENTRY
#define GL_ENTRY(name) decltype(&::name) name = symbol<decltype(&::name)>(library, #name, "/MobileGluesProbe.framework/")
    GL_ENTRY(glGetString); GL_ENTRY(glGetError); GL_ENTRY(glGetIntegerv);
    GL_ENTRY(glGenTextures); GL_ENTRY(glBindTexture); GL_ENTRY(glTexImage2D);
    GL_ENTRY(glTexParameteri); GL_ENTRY(glIsTexture); GL_ENTRY(glDeleteTextures);
    GL_ENTRY(glGenFramebuffers); GL_ENTRY(glBindFramebuffer); GL_ENTRY(glFramebufferTexture2D);
    GL_ENTRY(glCheckFramebufferStatus); GL_ENTRY(glDeleteFramebuffers);
    GL_ENTRY(glViewport); GL_ENTRY(glClearColor); GL_ENTRY(glClear); GL_ENTRY(glFinish);
    GL_ENTRY(glReadPixels);
#undef GL_ENTRY
    explicit Frontend(void *handle) : library(handle) {}
    void eglCheck(EGLBoolean ok, NSMutableString *report, const char *phase) {
        auto error = eglGetError();
        [report appendFormat:@"%s: result=%u EGL=0x%x\n", phase, ok, error];
        require(ok == EGL_TRUE && error == EGL_SUCCESS, phase);
    }
    void glCheck(NSMutableString *report, const char *phase) {
        auto error = glGetError();
        [report appendFormat:@"%s: GL=0x%x\n", phase, error];
        require(error == GL_NO_ERROR, phase);
    }
};

// Frontend handles must never be driven by the raw ANGLE function table.
// Cleanup is observable; this is a one-shot diagnostic, not a renderer session.
struct Session {
    Frontend& f;
    NSMutableString *report;
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext root = EGL_NO_CONTEXT, shared = EGL_NO_CONTEXT;
    GLuint texture = 0;
    bool initialized = false;
    bool close() {
        bool ok = true;
        auto check = [&](EGLBoolean result, const char *phase) {
            auto error = f.eglGetError();
            [report appendFormat:@"cleanup %s: result=%u EGL=0x%x\n", phase, result, error];
            ok = ok && result == EGL_TRUE && error == EGL_SUCCESS;
        };
        if (initialized) {
            if (root != EGL_NO_CONTEXT && texture) {
                EGLBoolean current = f.eglMakeCurrent(display, surface, surface, root);
                check(current, "restore root for texture release");
                if (current) { f.glDeleteTextures(1, &texture); texture = 0;
                    auto error = f.glGetError(); ok = ok && error == GL_NO_ERROR;
                    [report appendFormat:@"cleanup texture: GL=0x%x\n", error]; }
            }
            check(f.eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT), "unbind");
            if (shared != EGL_NO_CONTEXT) { check(f.eglDestroyContext(display, shared), "destroy shared"); shared = EGL_NO_CONTEXT; }
            if (root != EGL_NO_CONTEXT) { check(f.eglDestroyContext(display, root), "destroy root"); root = EGL_NO_CONTEXT; }
            if (surface != EGL_NO_SURFACE) { check(f.eglDestroySurface(display, surface), "destroy pbuffer"); surface = EGL_NO_SURFACE; }
            check(f.eglTerminate(display), "terminate frontend display");
            initialized = false;
        }
        check(f.eglReleaseThread(), "release owner thread");
        return ok;
    }
};

void verifyPixels(Frontend& f, GLuint texture, NSMutableString *report, const char *phase) {
    require(f.glIsTexture(texture) == GL_TRUE, "Shared texture is not visible");
    GLuint framebuffer = 0;
    f.glGenFramebuffers(1, &framebuffer);
    f.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    f.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    GLenum status = f.glCheckFramebufferStatus(GL_FRAMEBUFFER);
    std::array<GLubyte, 4> pixel{};
    if (status == GL_FRAMEBUFFER_COMPLETE)
        f.glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    f.glBindFramebuffer(GL_FRAMEBUFFER, 0);
    f.glDeleteFramebuffers(1, &framebuffer);
    f.glCheck(report, phase);
    [report appendFormat:@"%s: FBO=0x%x actual RGBA=%u,%u,%u,%u expected=51,153,230,255\n",
        phase, status, pixel[0], pixel[1], pixel[2], pixel[3]];
    require(status == GL_FRAMEBUFFER_COMPLETE && std::abs(int(pixel[0])-51) <= 1 &&
        std::abs(int(pixel[1])-153) <= 1 && std::abs(int(pixel[2])-230) <= 1 && pixel[3] == 255,
        "Cross-context GPU clear content mismatch");
}
}

NSString *RGPURunMobileGluesProbe(void) {
    NSMutableString *report = [NSMutableString stringWithString:
        @"B1.1 ISOLATED MobileGlues + ANGLE Metal Provider/Context Probe\n"
         "NOT VirGL integration, guest GL 3.2 acceptance, remote display or B1.2 shader acceptance.\n"];
    if (ran.exchange(true)) return @"One initialization attempt per process. Relaunch this standalone Probe to repeat; production RemoteGPU is unaffected.";
    struct utsname device{}; uname(&device);
    [report appendFormat:@"Device: %s; %@\n", device.machine, NSProcessInfo.processInfo.operatingSystemVersionString];
    NSString *manifest = [NSString stringWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"B11Provenance" withExtension:@"json"]
        encoding:NSUTF8StringEncoding error:nil];
    [report appendFormat:@"Build provenance: %@\n", manifest ?: @"MISSING"];
    try {
        require(manifest != nil, "Build provenance missing");
        NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/MobileGluesProbe"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        require(setenv("MG_DIR_PATH", directory.fileSystemRepresentation, 1) == 0, "Cannot install sandbox log path");
        // No MG customGLVersion, GL/GLSL override or capability override is set.
        void *backendEGL = load(@"EGL"), *backendGLES = load(@"GLESv2");
        void *frontend = load(@"MobileGluesProbe");
        auto boot = symbol<int (*)(void*, void*, void*)>(frontend, "rgpu_mg_bootstrap", "/MobileGluesProbe.framework/");
        auto bootError = symbol<const char* (*)()>(frontend, "rgpu_mg_bootstrap_error", "/MobileGluesProbe.framework/");
        auto resolved = symbol<unsigned long (*)()>(frontend, "rgpu_mg_resolved_count", "/MobileGluesProbe.framework/");
        // All identities checked before any frontend/backend function is executed.
        Frontend f(frontend);
        auto backendString = symbol<decltype(&::glGetString)>(backendGLES, "glGetString", "/GLESv2.framework/");
        auto backendInit = symbol<decltype(&::eglInitialize)>(backendEGL, "eglInitialize", "/EGL.framework/");
        auto backendProc = symbol<decltype(&::eglGetProcAddress)>(backendEGL, "eglGetProcAddress", "/EGL.framework/");
        auto backendError = symbol<decltype(&::eglGetError)>(backendEGL, "eglGetError", "/EGL.framework/");
        [report appendFormat:@"Frontend EGL provider: %s\nFrontend GL provider: %s\nBackend EGL provider: %s\nBackend GLES provider: %s\n",
            owner(reinterpret_cast<void*>(f.eglCreateContext)).c_str(), owner(reinterpret_cast<void*>(f.glGetString)).c_str(),
            owner(reinterpret_cast<void*>(backendInit)).c_str(), owner(reinterpret_cast<void*>(backendString)).c_str()];
        require(f.eglInitialize != backendInit && f.glGetString != backendString, "Frontend/backend recursion risk");
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            const std::string image = _dyld_get_image_name(i);
            // UIKit/CoreAnimation may preload system GLES on some OS builds.
            // Mere image presence does not identify the provider of OUR calls:
            // explicit RTLD_FIRST handles and pointer checks above/below do.
            if (image.find("/OpenGLES.framework/") != std::string::npos)
                [report appendFormat:@"OS-preloaded GLES image (NOT selected by Probe): %s\n", image.c_str()];
            require(image.find("/virglrenderer.") == std::string::npos &&
                image.find("/epoxy.") == std::string::npos, "Unexpected formal renderer loaded in isolated process");
        }
        int result = boot(frontend, backendEGL, backendGLES);
        [report appendFormat:@"Explicit bootstrap result=%d error=%s resolved_backend_entries=%lu\n", result, bootError(), resolved()];
        require(result == 0, "Explicit MobileGlues bootstrap failed (see error above)");
        const char *names[] = {"eglCreateContext", "eglMakeCurrent", "eglGetProcAddress", "glGetString", "glBindTexture", "glFramebufferTexture2D", "glReadPixels"};
        for (const char *name : names) {
            auto viaProc = reinterpret_cast<void*>(f.eglGetProcAddress(name));
            require(viaProc == dlsym(frontend, name), "Frontend proc lookup bypasses frontend symbol");
            [report appendFormat:@"Actual frontend %s ownership: %s; direct==proc YES\n", name, owner(viaProc).c_str()];
        }
        Session s{f, report};
        try {
            [report appendString:@"B11_STAGE resolve_platform_export_and_optional_proc\n"];
            // Pinned libEGL exports wrappers, whereas its proc table (in
            // libGLESv2/proc_table_egl_autogen.cpp) returns EGL_* implementations
            // in GLESv2. Validate both deterministic routes, not image-order luck.
            auto platform = symbol<PFNEGLGETPLATFORMDISPLAYEXTPROC>(backendEGL, "eglGetPlatformDisplayEXT", "/EGL.framework/");
            [report appendFormat:@"Backend EGL mandatory platform export: address=%p provider=%s VERIFIED\n",
                reinterpret_cast<void*>(platform), owner(reinterpret_cast<void*>(platform), "exported eglGetPlatformDisplayEXT").c_str()];
            const auto priorBackendError = backendError();
            void *platformImplementation = reinterpret_cast<void*>(backendProc("eglGetPlatformDisplayEXT"));
            const auto procError = backendError();
            Dl_info implementation{}, eglIdentity{}, glesIdentity{};
            const int implementationResolved = platformImplementation ? dladdr(platformImplementation, &implementation) : 0;
            require(dladdr(reinterpret_cast<void*>(backendInit), &eglIdentity) && eglIdentity.dli_fbase,
                "backend eglInitialize anchor identity unavailable");
            require(dladdr(reinterpret_cast<void*>(backendString), &glesIdentity) && glesIdentity.dli_fbase,
                "backend glGetString anchor identity unavailable");
            [report appendFormat:@"Backend optional eglGetProcAddress(eglGetPlatformDisplayEXT): address=%p dladdr=%d provider=%s prior_EGL=0x%x query_EGL=0x%x\n",
                platformImplementation, implementationResolved, implementation.dli_fname ?: "UNAVAILABLE", priorBackendError, procError];
            const auto procRoute = rgpu::b11::validateOptionalPlatform(platformImplementation,
                implementationResolved && implementation.dli_fname ? implementation.dli_fbase : nullptr,
                eglIdentity.dli_fbase, glesIdentity.dli_fbase);
            [report appendFormat:@"Backend optional platform proc route: %s; selected route=verified EGL exported wrapper\n",
                procRoute == rgpu::b11::OptionalRoute::verified ? "VERIFIED" : "UNAVAILABLE (not a required duplicate route; NOT a passed proc lookup)"];
            const EGLint metal[] = {0x3203, 0x3489, EGL_NONE};
            [report appendString:@"B11_STAGE frontend_display_initialize\n"];
            s.display = platform(0x3202, nullptr, metal);
            require(s.display != EGL_NO_DISPLAY, "ANGLE Metal display unavailable");
            f.eglCheck(f.eglInitialize(s.display, nullptr, nullptr), report, "frontend initialize explicit Metal display");
            s.initialized = true;
            f.eglCheck(f.eglBindAPI(EGL_OPENGL_API), report, "frontend bind virtual desktop API");
            require(f.eglQueryAPI() == EGL_OPENGL_API, "Frontend desktop API state not retained");
            const EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
            EGLConfig config{}; EGLint count = 0;
            f.eglCheck(f.eglChooseConfig(s.display, attrs, &config, 1, &count), report, "frontend desktop config translation");
            require(count == 1, "No frontend desktop pbuffer config");
            const EGLint size[] = {EGL_WIDTH, 4, EGL_HEIGHT, 4, EGL_NONE};
            s.surface = f.eglCreatePbufferSurface(s.display, config, size);
            f.eglCheck(s.surface != EGL_NO_SURFACE, report, "create pbuffer");
            const EGLint core[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, 3, EGL_CONTEXT_MINOR_VERSION_KHR, 2,
                EGL_CONTEXT_OPENGL_PROFILE_MASK_KHR, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR, EGL_NONE};
            [report appendString:@"B11_STAGE create_frontend_contexts\n"];
            s.root = f.eglCreateContext(s.display, config, EGL_NO_CONTEXT, core);
            f.eglCheck(s.root != EGL_NO_CONTEXT, report, "create frontend 3.2 Core request (metadata only, NOT capability gate)");
            s.shared = f.eglCreateContext(s.display, config, s.root, core);
            f.eglCheck(s.shared != EGL_NO_CONTEXT, report, "create shared frontend context");
            f.eglCheck(f.eglMakeCurrent(s.display, s.surface, s.surface, s.root), report, "make root current");
            require(f.eglGetCurrentContext() == s.root && f.eglGetCurrentDisplay() == s.display, "Frontend current-context identity mismatch");
            [report appendFormat:@"Frontend GL_VERSION (unverified metadata): %s\nFrontend GLSL_VERSION (unverified metadata): %s\nFrontend Renderer: %s\nBackend actual GL: %s\nBackend actual GLSL: %s\nBackend actual Renderer: %s\n",
                f.glGetString(GL_VERSION), f.glGetString(GL_SHADING_LANGUAGE_VERSION), f.glGetString(GL_RENDERER),
                backendString(GL_VERSION), backendString(GL_SHADING_LANGUAGE_VERSION), backendString(GL_RENDERER)];
            EGLint major = 0, minor = 0, profile = 0;
            f.eglCheck(f.eglQueryContext(s.display, s.root, EGL_CONTEXT_MAJOR_VERSION_KHR, &major), report, "query frontend context major");
            f.eglCheck(f.eglQueryContext(s.display, s.root, EGL_CONTEXT_MINOR_VERSION_KHR, &minor), report, "query frontend context minor");
            f.eglCheck(f.eglQueryContext(s.display, s.root, EGL_CONTEXT_OPENGL_PROFILE_MASK_KHR, &profile), report, "query frontend profile");
            [report appendFormat:@"Frontend context metadata: %d.%d profile=0x%x; NOT GL semantic conformance evidence\n", major, minor, profile];
            [report appendString:@"B11_STAGE shared_gpu_content_and_migration\n"];
            f.glGenTextures(1, &s.texture); f.glBindTexture(GL_TEXTURE_2D, s.texture);
            f.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            f.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            f.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
            GLuint framebuffer = 0; f.glGenFramebuffers(1, &framebuffer);
            f.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
            f.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s.texture, 0);
            bool complete = f.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
            if (complete) { f.glViewport(0, 0, 4, 4); f.glClearColor(0.2f, 0.6f, 0.9f, 1); f.glClear(GL_COLOR_BUFFER_BIT); f.glFinish(); }
            f.glBindFramebuffer(GL_FRAMEBUFFER, 0); f.glDeleteFramebuffers(1, &framebuffer);
            f.glCheck(report, "root GPU clear + one-shot local completion");
            require(complete, "Root FBO incomplete");
            f.eglCheck(f.eglMakeCurrent(s.display, s.surface, s.surface, s.shared), report, "switch to shared context");
            verifyPixels(f, s.texture, report, "shared-context GPU content");
            f.eglCheck(f.eglMakeCurrent(s.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT), report, "unbind owner before migration");
            require(f.eglGetCurrentContext() == EGL_NO_CONTEXT, "Owner context not unbound");
            std::string workerFailure;
            // No concurrent GL use: original owner waits; worker exclusively
            // acquires/releases the SAME root context, then returns ownership.
            std::thread worker([&] { @autoreleasepool {
                try {
                    f.eglCheck(f.eglBindAPI(EGL_OPENGL_API), report, "worker frontend API bind");
                    f.eglCheck(f.eglMakeCurrent(s.display, s.surface, s.surface, s.root), report, "worker bind migrated root");
                    require(f.eglGetCurrentContext() == s.root, "Worker current-context mismatch");
                    verifyPixels(f, s.texture, report, "migrated-context GPU content");
                } catch (const std::exception& e) { workerFailure = e.what(); }
                auto unbound = f.eglMakeCurrent(s.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
                auto released = f.eglReleaseThread();
                [report appendFormat:@"worker unbind=%u release=%u\n", unbound, released];
                if (!unbound || !released) workerFailure += " worker cleanup failed";
            }});
            worker.join();
            require(workerFailure.empty(), workerFailure.c_str());
            f.eglCheck(f.eglMakeCurrent(s.display, s.surface, s.surface, s.root), report, "return root to original owner");
            verifyPixels(f, s.texture, report, "returned-context GPU content");
            require(s.close(), "Frontend cleanup reported errors");
        } catch (...) { s.close(); throw; }
        [report appendString:@"PASS: B1.1 provider/context/content-sharing checks ONLY.\nB1.2 GLSL 150 shaders/features NOT TESTED. B1.3 VirGL/Ubuntu guest GL 3.2 NOT TESTED.\n"];
    } catch (const std::exception& e) {
        [report appendFormat:@"BLOCKED: %s\nNo backend substitution, version/capability override or production renderer modification applied.\n", e.what()];
    }
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/MobileGluesProbe/latest.log"];
    NSString *log = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (log) [report appendFormat:@"\nMobileGlues runtime log (bounded tail):\n%@\n", [log substringFromIndex:log.length > 32768 ? log.length - 32768 : 0]];
    [report appendString:@"Up to three 1x1 offscreen diagnostic CPU reads; no remote display, no frame streaming. Library images retained until process exit; context/texture cleanup above is separate from driver leak profiling.\n"];
    return report;
}
