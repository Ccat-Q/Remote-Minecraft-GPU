// RemoteGPU B1.1 loader adaptation for LGPL-2.1-only MobileGlues.
// Shipped as corresponding source with the exact upstream source snapshot.
#include "rgpu_probe_loader.h"
#include "includes.h"
#include "gles/loader.h"
#include <cstring>
#include <stdexcept>
#include <string>

namespace {
void *front = nullptr, *eglBase = nullptr, *glesBase = nullptr, *frontBase = nullptr;
unsigned long resolved = 0;
std::string failure;
bool attempted = false;
void *image(void *p) {
    Dl_info info{};
    if (!p || !dladdr(p, &info) || !info.dli_fbase)
        throw std::runtime_error("Cannot identify provider image");
    return info.dli_fbase;
}
void *checked(void *p, void *base, const char *name) {
    if (p && image(p) != base)
        throw std::runtime_error(std::string("Wrong provider/recursive binding: ") + name);
    return p;
}
}

extern "C" void *rgpu_mg_backend_symbol(void *lib, const char *name) {
    if (!attempted || (lib != egl && lib != gles) || !name)
        throw std::runtime_error("Backend resolver used before explicit installation");
    void *base = lib == egl ? eglBase : glesBase;
    void *p = dlsym(lib, name); // handles opened RTLD_FIRST by the probe
    if (!p && lib == gles) {
        // Optional extensions may exist only in ANGLE's entry-point table.
        auto get = reinterpret_cast<__eglMustCastToProperFunctionPointerType (*)(const char*)>(
            checked(dlsym(egl, "eglGetProcAddress"), eglBase, "eglGetProcAddress"));
        if (get) p = reinterpret_cast<void*>(get(name));
    }
    if (p) { checked(p, base, name); ++resolved; }
    return p; // unsupported optional symbols remain unavailable, never a frontend fallback
}

extern "C" void *rgpu_mg_frontend_symbol(const char *name) {
    if (!front || !name) throw std::runtime_error("Frontend resolver not installed");
    return checked(dlsym(front, name), frontBase, name);
}

extern "C" void *rgpu_mg_metal_display(void) {
    using Platform = EGLDisplay (*)(EGLenum, void*, const EGLint*);
    auto platform = reinterpret_cast<Platform>(rgpu_mg_backend_symbol(egl, "eglGetPlatformDisplayEXT"));
    if (!platform) {
        auto get = reinterpret_cast<__eglMustCastToProperFunctionPointerType (*)(const char*)>(
            rgpu_mg_backend_symbol(egl, "eglGetProcAddress"));
        if (!get) throw std::runtime_error("ANGLE backend proc resolver unavailable");
        platform = reinterpret_cast<Platform>(get("eglGetPlatformDisplayEXT"));
        // ANGLE's EGL_* proc table is implemented in GLESv2; either exact
        // installed ANGLE image is legitimate, never the frontend/global scope.
        if (platform) {
            void *base = image(reinterpret_cast<void*>(platform));
            if (base != eglBase && base != glesBase)
                throw std::runtime_error("Wrong ANGLE platform implementation provider");
        }
    }
    if (!platform) throw std::runtime_error("ANGLE Metal platform entry unavailable");
    const EGLint attrs[] = {0x3203 /* EGL_PLATFORM_ANGLE_TYPE_ANGLE */,
                           0x3489 /* EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE */, EGL_NONE};
    auto display = platform(0x3202 /* EGL_PLATFORM_ANGLE_ANGLE */, nullptr, attrs);
    if (display == EGL_NO_DISPLAY) throw std::runtime_error("ANGLE explicit Metal display failed");
    return display;
}

extern "C" int rgpu_mg_bootstrap(void *frontend, void *backendEGL, void *backendGLES) {
    if (attempted) return -2; // one initialization attempt per diagnostic process
    attempted = true;
    try {
        if (!frontend || !backendEGL || !backendGLES) throw std::runtime_error("Missing explicit handles");
        front = frontend; egl = backendEGL; gles = backendGLES;
        frontBase = image(dlsym(front, "rgpu_mg_bootstrap"));
        eglBase = image(dlsym(egl, "eglInitialize"));
        glesBase = image(dlsym(gles, "glGetString"));
        if (frontBase == eglBase || frontBase == glesBase || eglBase == glesBase)
            throw std::runtime_error("Frontend and backend providers must be distinct images");
        proc_init();
        // proc_init's temporary GLES context is already explicitly released.
        if (!GLES.glGetString || !GLES.glGetError || g_gles_caps.major < 3)
            throw std::runtime_error("MobileGlues bootstrap did not establish GLES 3 backend");
        return 0;
    } catch (const std::exception& e) {
        failure = e.what();
        // Early EGL failures already clear their handles; a later resolver or
        // GLES-probe failure must also release any successful temporary setup.
        if (frontBase && eglBase && glesBase) {
            try { destroy_temp_egl_ctx(); }
            catch (const std::exception& cleanup) { failure += std::string("; bootstrap cleanup: ") + cleanup.what(); }
        }
        return -1;
    }
}
extern "C" const char *rgpu_mg_bootstrap_error(void) { return failure.c_str(); }
extern "C" unsigned long rgpu_mg_resolved_count(void) { return resolved; }
