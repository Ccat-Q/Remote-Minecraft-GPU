#pragma once
// RemoteGPU B1.1 adaptation ABI, not a replacement for MobileGlues GL/EGL API.
#ifdef __cplusplus
extern "C" {
#endif
__attribute__((visibility("default"))) int rgpu_mg_bootstrap(void *frontend, void *backendEGL, void *backendGLES);
__attribute__((visibility("default"))) const char *rgpu_mg_bootstrap_error(void);
__attribute__((visibility("default"))) unsigned long rgpu_mg_resolved_count(void);
void *rgpu_mg_backend_symbol(void *library, const char *name);
void *rgpu_mg_frontend_symbol(const char *name);
void *rgpu_mg_metal_display(void);
#ifdef __cplusplus
}
#endif
