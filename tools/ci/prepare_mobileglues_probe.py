#!/usr/bin/env python3
"""Checked, isolated iPhone adaptation of ONE pinned MobileGlues checkout.

No version/capability changes. Run in Actions; never on the production sysroot.
Source changes are shipped with the IPA diagnostics for LGPL reproducibility.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

MOBILEGLUES = "97558a69157b033b890958b1e49258c5b51a80c6"
SUBMODULES = {
    "MobileGlues-cpp/3rdparty/glslang": "f5f664dee8146676b04a332a7233959fc3ce9681",
    "MobileGlues-cpp/3rdparty/SPIRV-Cross": "a0fba56c34a6700f1724bf9b751da5b488a3775c",
    "MobileGlues-cpp/3rdparty/xxhash": "c2866db364b6ea3a11933e62235ddc166ba18565",
    "MobileGlues-cpp/include/ska": "21c1cec95abee1beef827e4a7c95f692875d9594",
}
HASHES = {
    "CMakeLists.txt": "28b786899c3cbe144d5b367c84047c48aabf55b5ec0453163957958c0a4c9043",
    "init.cpp": "ba4dad2c5d19e8ef411b4425f8b6fed9421eb4c377d23cc5555205b57815bd1c",
    "main.cpp": "b92ba23e07a5c109f75e9e360c2a35d201a6263daab719a4f04d3fe051170ef9",
    "gles/loader.cpp": "a3d2a2cf44e41822711fc8b2df857905c777a7ea952ad064cf1d33f44aed6828",
    "glx/lookup.cpp": "894fb518435e7de0b4233301851282e42a7bf078f9ed8097aa9ef9d3fb345715",
    "egl/loader.cpp": "99c6fa02cf611f36c6d2082b83d047f234302bf8b5c6b9095697e33b0d69fdeb",
    "config/settings.cpp": "e677009b0390de2fc9fac11907c7cc859415e9780c1c5940d182f7b78c74c262",
    "gl/framebuffer.cpp": "e21359abeeabd2cae8a3f1da3ea71b38824a402351d847d87e5fa045915e7713",
    "egl/trace.h": "0db2d93b36253ff895b9fb3fc7e0b17624976fd1a94131bfe21f4db0521fac24",
}


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise ValueError(f"Pinned adaptation anchor changed: {before[:90]!r}")
    return source.replace(before, after)


def diagnostic_apple_errors(source):
    before = "    global_settings.angle_supported = false;\n    global_settings.ignore_error = IgnoreErrorLevel::Partial;"
    after = "    global_settings.angle_supported = false;\n    global_settings.ignore_error = IgnoreErrorLevel::None; // B1.1 diagnostic"
    return replace_once(source, before, after)


def adapt(sources, overlay):
    """Pure transform, shared by real CI preparation and mutation-guard tests."""
    for name, expected in HASHES.items():
        if hashlib.sha256(sources[name].encode()).hexdigest() != expected:
            raise ValueError(f"Unexpected pinned source: {name}")
    result = dict(sources)
    # Disable constructor bootstrap; the app installs validated library handles
    # before proc_init can resolve a single EGL/GLES function.
    result["init.cpp"] = overlay
    loader = sources["gles/loader.cpp"]
    first = loader.index("void load_libs() {\n")
    last = loader.index("\nvoid set_hardware()", first)
    result["gles/loader.cpp"] = loader[:first] + '''void load_libs() {
    // B1.1 explicit bootstrap only: no global lookup or system-driver fallback.
    if (!egl || !gles) throw std::runtime_error("B11 backend handles not installed");
    g_angle_in_use = true;
}

void* proc_address(void* lib, const char* name) {
    return rgpu_mg_backend_symbol(lib, name);
}
''' + loader[last:]
    result["gles/loader.cpp"] = '#include "../rgpu_probe_loader.h"\n#include <stdexcept>\n' + result["gles/loader.cpp"]
    result["glx/lookup.cpp"] = '#include "../rgpu_probe_loader.h"\n' + replace_once(
        sources["glx/lookup.cpp"],
        "return dlsym((void*)(~(uintptr_t)0), real_func_name.c_str());",
        "return rgpu_mg_frontend_symbol(real_func_name.c_str());")
    # Select Metal explicitly; EGL_DEFAULT_DISPLAY must not pick another backend.
    result["egl/loader.cpp"] = '#include "../rgpu_probe_loader.h"\n#include <stdexcept>\n' + replace_once(
        sources["egl/loader.cpp"],
        "eglDisplay = egl_eglGetDisplay(EGL_DEFAULT_DISPLAY);",
        "eglDisplay = (EGLDisplay)rgpu_mg_metal_display();")
    result["egl/loader.cpp"] = replace_once(result["egl/loader.cpp"],
        '    ETRACE("init_target_egl: probe FAILED, all three handles released")',
        '    throw std::runtime_error("MobileGlues bootstrap EGL initialization failed; see runtime log");')
    # Diagnostics must observe driver errors, not upstream's Apple partial-ignore
    # policy. No version string, feature or extension advertisement is changed.
    result["config/settings.cpp"] = diagnostic_apple_errors(sources["config/settings.cpp"])
    # Three ARB entry points missed upstream's Apple forwarding-wrapper guard.
    # Mach-O rejects ELF alias attributes; keep identical signatures/behavior.
    framebuffer = sources["gl/framebuffer.cpp"]
    for before, after in (
        ('__attribute__((alias("glDeleteFramebuffers")));', '{ glDeleteFramebuffers(n, names); }'),
        ('__attribute__((alias("glFramebufferRenderbuffer")));', '{ glFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer); }'),
        ('__attribute__((alias("glFramebufferTextureLayer")));', '{ glFramebufferTextureLayer(target, attachment, texture, level, layer); }'),
    ):
        framebuffer = replace_once(framebuffer, before, after)
    result["gl/framebuffer.cpp"] = framebuffer
    trace = replace_once(sources["egl/trace.h"], "#include <sys/syscall.h>", "#include <pthread.h>\n#include <stdint.h>")
    trace = replace_once(trace,
        "static inline int mg_egl_tid(void) {\n    return (int)syscall(__NR_gettid);\n}",
        "static inline unsigned long long mg_egl_tid(void) {\n    uint64_t tid = 0;\n    pthread_threadid_np(nullptr, &tid);\n    return (unsigned long long)tid;\n}")
    result["egl/trace.h"] = replace_once(trace, '#define EGL_TRACE_TAG "[EGL t%d] "', '#define EGL_TRACE_TAG "[EGL t%llu] "')
    # Upstream Apple leaves the bootstrap context current. Unbind and destroy it
    # on Apple too before the app creates its frontend context/share group.
    result["main.cpp"] = replace_once(sources["main.cpp"],
        "#ifndef __APPLE__\n    destroy_temp_egl_ctx();\n#endif",
        "destroy_temp_egl_ctx(); // B1.1: also release Apple's bootstrap context")
    # Keep dependency options and exact upstream source list, replace only its
    # non-portable target/toolchain setup. Do not link any GL framework here:
    # every backend entry goes through the explicit handle resolver.
    cmake = sources["CMakeLists.txt"]
    options = cmake[cmake.index("# glslang & SPIRV-Cross"):cmake.index("if(MACOS)")]
    match = re.search(r"add_library\(\$\{CMAKE_PROJECT_NAME\} SHARED\n(.*?)\n\)", cmake, re.S)
    if not match:
        raise ValueError("Pinned MobileGlues compilation unit list changed")
    result["CMakeLists.txt"] = '''cmake_minimum_required(VERSION 3.22.1)
project(MobileGluesProbe LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
''' + options + '''
add_library(MobileGluesProbe SHARED
''' + match[1] + '''
)
target_include_directories(MobileGluesProbe PRIVATE includes include 3rdparty/xxhash)
target_compile_options(MobileGluesProbe PRIVATE -fvisibility=hidden -Wno-deprecated-declarations)
target_link_libraries(MobileGluesProbe PRIVATE glslang::glslang spirv-cross-c)
set_target_properties(MobileGluesProbe PROPERTIES
  FRAMEWORK TRUE FRAMEWORK_VERSION A
  MACOSX_FRAMEWORK_IDENTIFIER org.remotegpu.experiments.mobileglues.library
  INSTALL_NAME_DIR "@rpath"
  BUILD_WITH_INSTALL_NAME_DIR TRUE
  XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
'''
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    def git(*parts):
        return subprocess.check_output(["git", "-C", str(args.source), *parts], text=True).strip()
    if git("rev-parse", "HEAD") != MOBILEGLUES or git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Require clean, pinned MobileGlues checkout")
    for path, expected in SUBMODULES.items():
        actual = subprocess.check_output(["git", "-C", str(args.source / path), "rev-parse", "HEAD"], text=True).strip()
        if actual != expected:
            raise ValueError(f"Unexpected dependency revision: {path}")
    root = args.source / "MobileGlues-cpp"
    sources = {name: (root / name).read_text() for name in HASHES}
    result = adapt(sources, (args.overlay / "Bootstrap.cpp").read_text())
    result["rgpu_probe_loader.h"] = (args.overlay / "Bootstrap.h").read_text()
    for name, content in result.items():
        (root / name).write_text(content)
    # Corresponding source modifications and overlay accompany every IPA.
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps({
        "mobileglues_sha": MOBILEGLUES, "submodules": SUBMODULES,
        "upstream_sha256": HASHES,
        "adapted_sha256": {name: hashlib.sha256(content.encode()).hexdigest() for name, content in result.items()},
        "recipe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "scope": "B1.1 isolated provider/context experiment; not VirGL or guest GL acceptance",
    }, indent=2, sort_keys=True) + "\n")
    print(args.manifest.read_text())


if __name__ == "__main__":
    main()
