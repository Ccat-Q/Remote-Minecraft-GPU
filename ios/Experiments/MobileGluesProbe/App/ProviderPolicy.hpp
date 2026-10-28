#pragma once
#include <stdexcept>

namespace rgpu::b11 {
enum class OptionalRoute { unavailable, verified };

// An exported EGL entry and an extension proc-table query are distinct routes.
// Absence of the unused duplicate query is diagnostic, not a missing feature.
// A non-null pointer must STILL belong to one of the exact installed ANGLE
// images. Do not turn unresolved or foreign pointers into optional successes.
inline OptionalRoute validateOptionalPlatform(void *address, const void *image,
                                             const void *eglImage, const void *glesImage) {
    if (!address) return OptionalRoute::unavailable;
    if (!image)
        throw std::runtime_error("eglGetProcAddress(eglGetPlatformDisplayEXT): non-null pointer has no dladdr identity");
    if (!eglImage || !glesImage || (image != eglImage && image != glesImage))
        throw std::runtime_error("eglGetProcAddress(eglGetPlatformDisplayEXT): foreign provider rejected");
    return OptionalRoute::verified;
}
}
