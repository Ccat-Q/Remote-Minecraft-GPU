# iOS renderer dependency baseline

The first renderer dependency build is pinned to UTM commit
`9d00a54833184628c696bcbfafbf344cea566e59`. UTM is the reference because its
iOS sysroot build already combines ANGLE's Metal backend, libepoxy and its
Apple-specific virglrenderer fork.

Run **Build iOS renderer sysroot** in GitHub Actions. It applies a checked
renderer-only recipe to UTM's `build_dependencies.sh -p ios -a arm64`, keeping
the upstream toolchain, ANGLE build and framework fixups. It caches the resulting
`sysroot-iOS-arm64` (the upstream path is case-sensitive) by UTM revision,
runner architecture and build recipe, and checks that the sysroot contains
virglrenderer plus `EGL.framework` and `GLESv2.framework`.
Before publishing, the workflow compiles and links `tests/ios_renderer_link.c`
with the iPhoneOS SDK against ANGLE and virglrenderer. This verifies device
architecture and the public API linkage; it does not execute the renderer,
prove iPhone GL capability, or test presentation.
ANGLE is linked as `EGL.framework` and `GLESv2.framework` from the sysroot,
not with `-lGLESv2`, which can select an iOS SDK private library instead.
The WebKit ANGLE build also sets a WebCore-only library client list. The
RemoteGPU recipe overrides `LD_DYLIB_ALLOWABLE_CLIENTS` to an empty list while
building our open-source ANGLE libraries. The link gate inspects Mach-O load
commands and rejects a GLESv2 framework that still restricts its clients.

The pinned virglrenderer has a label immediately before a local declaration,
which Apple Clang rejects in C11. `tools/ci/prepare_utm_renderer.py` inserts an
empty statement after that label before the renderer compiles. The patch
checks its source context and fails if the pinned source changes; remove it
when upgrading to a revision that includes the fix. Build logs are uploaded
even when compilation fails. Completed sysroots use exact cache keys only,
so changing a recipe cannot silently reuse an incompatible output.

The sysroot key includes the Xcode, iPhoneOS SDK and Clang fingerprint.
Cross C/C++/Objective-C compilation is wrapped with ccache; the compiler cache
and downloaded source archives are saved even after partial build failures.
Generated build directories are not cached. ANGLE's separate Xcode archive
build does not use this ccache wrapper. The recipe downloads and builds only
pkg-config, libffi, libiconv, gettext, GLib, ANGLE, libepoxy and virglrenderer.
QEMU, SPICE, Hypervisor, Vulkan/Venus/Neptune and D3D are excluded. Both Venus
and Neptune are explicitly disabled in virglrenderer; the v1 renderer is the
OpenGL/EGL route. This dependency build still needs a successful CI run before
the sysroot can be used by an app.

This sysroot is a build prerequisite, not a renderer implementation. The
RemoteGPU app must still add an iOS vtest adapter that renders to an
IOSurface-backed EGL surface and presents it through `CAMetalLayer` without a
framebuffer readback.
