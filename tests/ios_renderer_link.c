/* Build/link only, on GitHub Actions with the iPhoneOS SDK. Never executed on
 * macOS: device rendering and the GL capability gate require an actual iPhone.
 * References both public APIs so the linker checks the produced dependencies.
 */
#include <EGL/egl.h>
#include <virglrenderer.h>

int remotegpu_renderer_link_probe(void *cookie,
                                 struct virgl_renderer_callbacks *callbacks)
{
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY)
        return -1;
    return virgl_renderer_init(cookie, 0, callbacks);
}
