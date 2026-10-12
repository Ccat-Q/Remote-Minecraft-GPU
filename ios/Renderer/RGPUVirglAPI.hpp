#pragma once
// The installed C API header does not provide a C++ linkage guard.
extern "C" {
#include <virgl/virglrenderer.h>
}

// virglrenderer.h only forward-declares this argument. ABI from pinned UTM
// virglrenderer 482f9d8 src/virgl_hw.h (not installed in the iOS sysroot).
struct virgl_box { uint32_t x, y, z, w, h, d; };
static_assert(sizeof(virgl_box) == 24, "virgl transfer box ABI");
