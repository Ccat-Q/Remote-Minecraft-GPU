#import "Probe.h"
#include "../Overlay/Bootstrap.h"
#include "ContextMetadata.hpp"
#if RGPU_B12_SHADER_PROBE
#include "../Shader/ShaderProbe.h"
#endif
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
#if RGPU_B12_STRICT_RETEST
        @"B1.2d.1 TBO REPAIR REVISION — SAME CAPABILITY GATES\n"
         "Device acceptance pending. Typed TBO lowering and BufferData/SubData attachment propagation; strict error control then B1.1/a/b/c and unchanged B1.2d gates. Geometry remains BLOCKED on the existing backend. NOT full TBO, B1.2, VirGL or guest acceptance.\n"];
#elif RGPU_B12_CORE_PROBE
        @"B1.2d ISOLATED TEXTURE BUFFER / GEOMETRY CAPABILITY PROBE\n"
         "Device acceptance pending. B1.1/B1.2a/B1.2b/B1.2c regressions run first. Each new feature uses a fresh unshared context. NOT full B1.2, VirGL or guest acceptance.\n"];
#elif RGPU_B12_RASTER_PROBE
        @"B1.2c ISOLATED DEPTH / STENCIL / BLENDING PROBE\n"
         "Device acceptance pending. B1.1/B1.2a/B1.2b regressions run first. NOT full B1.2, cross-context sync, VirGL or guest GL acceptance.\n"];
#elif RGPU_B12_FEATURE_PROBE
        @"B1.2b ISOLATED INSTANCING AND SAME-CONTEXT SYNC PROBE\n"
         "Device acceptance pending. B1.1/B1.2a regressions run first. NOT full B1.2, cross-context sync, VirGL or guest GL acceptance.\n"];
#elif RGPU_B12_SHADER_PROBE
        @"B1.2a ISOLATED GLSL150 VERTEX/FRAGMENT DYNAMIC OUTPUT PROBE\n"
         "Device acceptance pending. NOT full B1.2, VirGL, guest GL3.2 or Minecraft acceptance. B1.1 context regression runs first.\n"];
#else
        @"B1.1 ISOLATED MobileGlues + ANGLE Metal Provider/Context Probe\n"
         "NOT VirGL integration, guest GL 3.2 acceptance, remote display or B1.2 shader acceptance.\n"];
#endif
    if (ran.exchange(true)) return @"One initialization attempt per process. Relaunch this standalone Probe to repeat; production RemoteGPU is unaffected.";
    struct utsname device{}; uname(&device);
    [report appendFormat:@"Device: %s; %@\n", device.machine, NSProcessInfo.processInfo.operatingSystemVersionString];
    NSString *manifest = [NSString stringWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"B11Provenance" withExtension:@"json"]
        encoding:NSUTF8StringEncoding error:nil];
    [report appendFormat:@"Build provenance: %@\n", manifest ?: @"MISSING"];
#if RGPU_B12_CORE_PROBE
    std::array<rgpu::b12::Verdict,3> capabilityVerdicts{};
#endif
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
        auto acquireDisplay = symbol<decltype(&rgpu_mg_acquire_metal_display)>(frontend,
            "rgpu_mg_acquire_metal_display", "/MobileGluesProbe.framework/");
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
            [report appendString:@"B11_STAGE acquire_metal_display_shared_resolver\n"];
            const auto priorBackendError = backendError();
            void *display = nullptr, *platformImplementation = nullptr;
            int route = 0;
            const int acquired = acquireDisplay(&display, &platformImplementation, &route);
            const auto displayError = backendError();
            [report appendFormat:@"Shared Metal display acquisition result=%d error=%s route=%d entry=%p display=%p prior_EGL=0x%x acquire_EGL=0x%x\n",
                acquired, bootError(), route, platformImplementation, display, priorBackendError, displayError];
            require(acquired == 0 && display && platformImplementation, "Shared Metal display acquisition failed (see error above)");
            require(displayError == EGL_SUCCESS, "Shared Metal display acquisition reported EGL error");
            Dl_info implementation{}, eglIdentity{}, glesIdentity{};
            require(dladdr(platformImplementation, &implementation) && implementation.dli_fbase && implementation.dli_fname,
                "Selected platform entry identity unavailable");
            require(dladdr(reinterpret_cast<void*>(backendInit), &eglIdentity) && eglIdentity.dli_fbase,
                "backend eglInitialize anchor identity unavailable");
            require(dladdr(reinterpret_cast<void*>(backendString), &glesIdentity) && glesIdentity.dli_fbase,
                "backend glGetString anchor identity unavailable");
            require(route == 1 || route == 2, "Unknown platform route");
            require(implementation.dli_fbase == eglIdentity.dli_fbase ||
                (route == 2 && implementation.dli_fbase == glesIdentity.dli_fbase), "Selected platform entry has foreign provider");
            [report appendFormat:@"Backend selected platform route=%s provider=%s VERIFIED; bootstrap and App share resolver\n",
                route == 1 ? "EGL_DIRECT_EXPORT" : "ANGLE_PROC_TABLE (direct export absent)", implementation.dli_fname];
            [report appendString:@"B11_STAGE frontend_display_initialize\n"];
            s.display = static_cast<EGLDisplay>(display);
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
#if RGPU_B12_STRICT_RETEST
            // Intentional, bounded negative control before any content regression.
            auto rawError = symbol<decltype(&::glGetError)>(backendGLES,"glGetError","/GLESv2.framework/");
            using DepthFunc = void (*)(GLenum);
            auto depthFunc = symbol<DepthFunc>(frontend,"glDepthFunc","/MobileGluesProbe.framework/");
            Dl_info depthOwner{}, frontOwner{};
            require(dladdr(reinterpret_cast<void*>(depthFunc),&depthOwner) &&
                dladdr(reinterpret_cast<void*>(f.glGetString),&frontOwner) && depthOwner.dli_fbase &&
                depthOwner.dli_fbase == frontOwner.dli_fbase &&
                reinterpret_cast<void*>(depthFunc) == reinterpret_cast<void*>(f.eglGetProcAddress("glDepthFunc")),
                "Strict negative-control provider/direct-proc mismatch");
            const auto priorFront = f.glGetError(), priorRaw = rawError();
            [report appendFormat:@"B12D1_ERROR_CONTROL prior_front=0x%x prior_raw=0x%x provider=%s\n",priorFront,priorRaw,depthOwner.dli_fname];
            require(priorFront == GL_NO_ERROR && priorRaw == GL_NO_ERROR,"Strict control entry has prior GL errors; not discarded");
            depthFunc(static_cast<GLenum>(0xffffffffu));
            const auto observed = f.glGetError(), drained = f.glGetError(), remainingRaw = rawError();
            [report appendFormat:@"B12D1_ERROR_CONTROL invalid_depth_func actual=0x%x expected=0x%x next_front=0x%x remaining_raw=0x%x\n",
                observed,GL_INVALID_ENUM,drained,remainingRaw];
            require(observed == GL_INVALID_ENUM && drained == GL_NO_ERROR && remainingRaw == GL_NO_ERROR,
                "Strict error negative control failed; regressions NOT RUN");
            [report appendString:@"PASS: B1.2d.1 intentional invalid-enum error return/drain control ONLY. No capability acceptance.\n"];
#endif
            [report appendFormat:@"Frontend GL_VERSION (unverified metadata): %s\nFrontend GLSL_VERSION (unverified metadata): %s\nFrontend Renderer: %s\nBackend actual GL: %s\nBackend actual GLSL: %s\nBackend actual Renderer: %s\n",
                f.glGetString(GL_VERSION), f.glGetString(GL_SHADING_LANGUAGE_VERSION), f.glGetString(GL_RENDERER),
                backendString(GL_VERSION), backendString(GL_SHADING_LANGUAGE_VERSION), backendString(GL_RENDERER)];
            [report appendString:@"B11_STAGE context_metadata_correct_api\n"];
            static_assert(rgpu::b11::eglContextClientType == EGL_CONTEXT_CLIENT_TYPE && rgpu::b11::eglConfigId == EGL_CONFIG_ID);
            static_assert(rgpu::b11::glMajorVersion == GL_MAJOR_VERSION && rgpu::b11::glMinorVersion == GL_MINOR_VERSION);
            const auto metadata = rgpu::b11::queryContextMetadata([&](int attribute) {
                EGLint value = 0;
                const auto ok = f.eglQueryContext(s.display, s.root, attribute, &value);
                [report appendFormat:@"Frontend EGL context query attribute=0x%x result=%u value=%d\n", attribute, ok, value];
                f.eglCheck(ok, report, "query frontend EGL context metadata");
                return value;
            }, [&](unsigned token) {
                GLint value = 0;
                f.glGetIntegerv(token, &value);
                [report appendFormat:@"Frontend GL context query token=0x%x value=%d\n", token, value];
                f.glCheck(report, "query frontend GL context metadata");
                return value;
            });
            require(metadata.clientType == EGL_OPENGL_API, "Frontend context client type mismatch");
            [report appendFormat:@"Frontend context metadata via GL: %d.%d profile=0x%x EGL_client_type=0x%x config_id=%d; NOT GL semantic conformance evidence\n",
                metadata.major, metadata.minor, metadata.profile, metadata.clientType, metadata.configId];
            [report appendString:@"Metadata source caveat: pinned MobileGlues GL major/minor use granted request bookkeeping; profile getter returns a fixed Core bit. NOT capability proof. GPU content/sharing/migration checks still required.\n"];
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
#if RGPU_B12_SHADER_PROBE
            auto checkedEntry = [&](void *library, const char *name, const char *path, void *anchor) {
                void *entry = symbol<void*>(library,name,path);
                Dl_info actual{}, expected{};
                require(dladdr(entry,&actual) && dladdr(anchor,&expected) && actual.dli_fbase &&
                    actual.dli_fbase == expected.dli_fbase,"B12 function has wrong exact provider image");
                [report appendFormat:@"B12_ENTRY name=%s provider=%s\n",name,actual.dli_fname];
                return entry;
            };
            auto frontendEntry = [&](const char *name) {
                void *entry = checkedEntry(frontend,name,"/MobileGluesProbe.framework/",reinterpret_cast<void*>(f.glGetString));
                require(entry == reinterpret_cast<void*>(f.eglGetProcAddress(name)),"B12 frontend direct/proc ownership mismatch");
                return entry;
            };
            auto backendEntry = [&](const char *name) {
                return checkedEntry(backendGLES,name,"/GLESv2.framework/",reinterpret_cast<void*>(backendString));
            };
            RGPURunShaderDrawProbe(report,frontendEntry,backendEntry);
#if RGPU_B12_FEATURE_PROBE
            RGPURunInstancingSyncProbe(report,frontendEntry,backendEntry);
#endif
#if RGPU_B12_RASTER_PROBE
            RGPURunRasterProbe(report,frontendEntry,backendEntry);
#endif
#if RGPU_B12_CORE_PROBE
            for (size_t index = 0; index < rgpu::b12::capabilityKinds.size(); ++index) {
                EGLContext isolated = EGL_NO_CONTEXT;
                const char *name = rgpu::b12::capabilityNames[index];
                try {
                    isolated = f.eglCreateContext(s.display,config,EGL_NO_CONTEXT,core);
                    f.eglCheck(isolated != EGL_NO_CONTEXT,report,"create fresh unshared B1.2d context");
                    f.eglCheck(f.eglMakeCurrent(s.display,s.surface,s.surface,isolated),report,"make B1.2d context current");
                    require(f.eglGetCurrentContext() == isolated,"B1.2d current context mismatch");
                    RGPURunCapabilityProbe(report,frontendEntry,backendEntry,rgpu::b12::capabilityKinds[index]);
                    capabilityVerdicts[index] = rgpu::b12::Verdict::Passed;
                    [report appendFormat:@"B12D_FEATURE feature=%s result=PASS representative_cases_only\n",name];
                } catch (const std::exception& e) {
                    capabilityVerdicts[index] = rgpu::b12::Verdict::Blocked;
                    [report appendFormat:@"B12D_FEATURE feature=%s result=BLOCKED error=%s; later unexecuted steps NOT RUN\n",name,e.what()];
                }
                // Always restore the accepted root. A feature failure is retained,
                // never cleared into a PASS, and cannot suppress the next fresh
                // context. Failed EGL recovery instead stops the suite safely.
                const auto unbound = f.eglMakeCurrent(s.display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
                const auto unbindError = f.eglGetError();
                const auto restored = f.eglMakeCurrent(s.display,s.surface,s.surface,s.root);
                const auto restoreError = f.eglGetError();
                EGLBoolean destroyed = EGL_TRUE; EGLint destroyError = EGL_SUCCESS;
                if (isolated != EGL_NO_CONTEXT && restored) {
                    destroyed = f.eglDestroyContext(s.display,isolated); destroyError = f.eglGetError();
                } else if (isolated != EGL_NO_CONTEXT) {
                    destroyed = EGL_FALSE; // retained until process exit; never freed while binding is uncertain
                }
                [report appendFormat:@"B12D_CONTEXT_CLEANUP feature=%s allocated=%s unbind=%u/0x%x restore_root=%u/0x%x destroy=%u/0x%x (destroy skipped if not allocated; retained if restore fails)\n",
                    name,isolated != EGL_NO_CONTEXT ? "YES" : "NO",unbound,unbindError,restored,restoreError,destroyed,destroyError];
                require(unbound && unbindError == EGL_SUCCESS && restored && restoreError == EGL_SUCCESS &&
                    destroyed && destroyError == EGL_SUCCESS && f.eglGetCurrentContext() == s.root,
                    "B1.2d context recovery/cleanup failed; suite stopped, not device acceptance");
            }
#endif
#endif
            require(s.close(), "Frontend cleanup reported errors");
        } catch (...) { s.close(); throw; }
#if RGPU_B12_CORE_PROBE
        for (size_t index = 0; index < capabilityVerdicts.size(); ++index)
            [report appendFormat:@"B12D_SUMMARY feature=%s result=%s\n",rgpu::b12::capabilityNames[index],
                capabilityVerdicts[index] == rgpu::b12::Verdict::Passed ? "PASS" :
                capabilityVerdicts[index] == rgpu::b12::Verdict::Blocked ? "BLOCKED" : "NOT_RUN"];
        [report appendString:rgpu::b12::allCapabilitiesPassed(capabilityVerdicts) ?
            @"PASS: B1.2d representative signed/float Texture Buffer initial/update/reattach and Geometry outputs plus B1.1/a/b/c regressions and cleanup ONLY. NOT full B1.2, cross-context sync, limits, VirGL/guest GL, Minecraft, performance or leak acceptance.\n" :
            @"BLOCKED: B1.2d one or more required capability tests failed; individual results above are retained. Prior B1.1/a/b/c regression success is NOT full B1.2 or guest acceptance. No capability override or backend substitution applied.\n"];
#elif RGPU_B12_RASTER_PROBE
        [report appendString:@"PASS: B1.2c representative Depth/Stencil/Blending plus B1.1/B1.2a/B1.2b regressions and cleanup calls ONLY. TextureBuffer/Geometry, full B1.2, cross-context synchronization and guest GL NOT ACCEPTED.\n"];
#elif RGPU_B12_FEATURE_PROBE
        [report appendString:@"PASS: B1.2b representative instancing/same-context sync plus B1.1/B1.2a regressions and cleanup calls ONLY. Full B1.2, cross-context synchronization and guest GL NOT ACCEPTED.\n"];
#elif RGPU_B12_SHADER_PROBE
        [report appendString:@"PASS: B1.2a representative shader/dynamic-output checks plus B1.1 context regression and cleanup calls ONLY. Full B1.2 and B1.3/guest GL NOT ACCEPTED.\n"];
#else
        [report appendString:@"PASS: B1.1 provider/context/content-sharing checks ONLY.\nB1.2 GLSL 150 shaders/features NOT TESTED. B1.3 VirGL/Ubuntu guest GL 3.2 NOT TESTED.\n"];
#endif
    } catch (const std::exception& e) {
        [report appendFormat:@"BLOCKED: %s\nNo backend substitution, version/capability override or production renderer modification applied.\n", e.what()];
    }
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/MobileGluesProbe/latest.log"];
    NSString *log = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (log) [report appendFormat:@"\nMobileGlues runtime log (bounded tail):\n%@\n", [log substringFromIndex:log.length > 32768 ? log.length - 32768 : 0]];
#if RGPU_B12_CORE_PROBE
    [report appendString:@"Local diagnostics ONLY: B1.1 up to three 1x1 reads; B1.2a/b/c ten 16x16 reads; B1.2d at most eight 16x16 reads. Explicit reattach is diagnostic, never waives failed live updates. No remote display/streaming, performance or driver-leak verdict.\n"];
#elif RGPU_B12_RASTER_PROBE
    [report appendString:@"Local diagnostics ONLY: B1.1 up to three 1x1 reads; B1.2a/b each up to three and B1.2c up to four 16x16 reads. No remote display/streaming, performance or driver-leak verdict.\n"];
#elif RGPU_B12_FEATURE_PROBE
    [report appendString:@"Local diagnostics ONLY: B1.1 up to three 1x1 reads; B1.2a and B1.2b each up to three 16x16 reads. No remote display/streaming, performance or driver-leak verdict.\n"];
#elif RGPU_B12_SHADER_PROBE
    [report appendString:@"B1.1 regression: up to three 1x1 reads. B1.2a oracle: up to three 16x16 offscreen reads. Local diagnostics ONLY; no remote display or frame streaming. Library images retained until process exit; driver leak profiling NOT TESTED.\n"];
#else
    [report appendString:@"Up to three 1x1 offscreen diagnostic CPU reads; no remote display, no frame streaming. Library images retained until process exit; context/texture cleanup above is separate from driver leak profiling.\n"];
#endif
    return report;
}
