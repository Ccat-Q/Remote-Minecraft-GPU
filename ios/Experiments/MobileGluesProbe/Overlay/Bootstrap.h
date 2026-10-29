#pragma once
// RemoteGPU B1.1 adaptation ABI, not a replacement for MobileGlues GL/EGL API.
#ifdef __cplusplus
extern "C" {
#endif
__attribute__((visibility("default"))) int rgpu_mg_bootstrap(void *frontend, void *backendEGL, void *backendGLES);
__attribute__((visibility("default"))) const char *rgpu_mg_bootstrap_error(void);
__attribute__((visibility("default"))) unsigned long rgpu_mg_resolved_count(void);
// Checked ABI: no C++ exceptions escape. Requires successful bootstrap;
// outputs are cleared on failure, and bootstrap_error contains the reason.
__attribute__((visibility("default"))) int rgpu_mg_acquire_metal_display(void **display, void **entry, int *route);
void *rgpu_mg_backend_symbol(void *library, const char *name);
void *rgpu_mg_frontend_symbol(const char *name);
void *rgpu_mg_metal_display(void);
#ifdef __cplusplus
}

#include <stdexcept>
namespace rgpu::b11 {
enum class PlatformRoute { exported = 1, proc = 2 };
struct PlatformEntry { void *address; PlatformRoute route; };

// Shared by bootstrap and the exported App ABI. Query the proc table only
// when the direct export is absent, never to recover from a foreign pointer.
template<class ExportLookup, class ProcLookup, class Identify>
PlatformEntry selectPlatform(ExportLookup exported, ProcLookup proc, Identify identify,
                             const void *eglImage, const void *glesImage) {
    if (!eglImage || !glesImage || eglImage == glesImage)
        throw std::runtime_error("Platform resolver requires distinct ANGLE image anchors");
    void *address = exported();
    auto route = PlatformRoute::exported;
    if (!address) { address = proc(); route = PlatformRoute::proc; }
    if (!address) throw std::runtime_error("ANGLE Metal platform entry unavailable (export and proc absent)");
    const void *base = identify(address);
    if (!base) throw std::runtime_error("ANGLE platform entry has no dladdr identity");
    if (base != eglImage && (route != PlatformRoute::proc || base != glesImage))
        throw std::runtime_error("Wrong ANGLE platform implementation provider");
    return {address, route};
}
}
#endif
