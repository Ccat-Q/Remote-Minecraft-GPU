#pragma once

namespace rgpu::b11 {
// API tokens only, not advertised capabilities. Keep this portable query plan
// testable without loading a GL provider. Values come exclusively from callbacks.
inline constexpr int eglContextClientType = 0x3097, eglConfigId = 0x3028;
inline constexpr unsigned glMajorVersion = 0x821B, glMinorVersion = 0x821C;
inline constexpr unsigned glContextProfileMask = 0x9126;
struct ContextMetadata {
    int clientType, configId, major, minor, profile;
};

// EGL_KHR_create_context does not add minor/profile eglQueryContext queries.
// Those are GL queries after make-current, not EGL creation attributes passed
// back to eglQueryContext. No version/profile acceptance decision is made here.
template<class QueryEGL, class QueryGL>
ContextMetadata queryContextMetadata(QueryEGL egl, QueryGL gl) {
    return {egl(eglContextClientType), egl(eglConfigId),
            gl(glMajorVersion), gl(glMinorVersion), gl(glContextProfileMask)};
}
}
