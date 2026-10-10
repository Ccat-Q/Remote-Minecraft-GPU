# iOS renderer dependency baseline

The first renderer dependency build is pinned to UTM commit
`9d00a54833184628c696bcbfafbf344cea566e59`. UTM is the reference because its
iOS sysroot build already combines ANGLE's Metal backend, libepoxy and its
Apple-specific virglrenderer fork.

Run **Build iOS renderer sysroot** in GitHub Actions. It invokes UTM's
`build_dependencies.sh -p ios -a arm64`, caches the resulting
`sysroot-iOS-arm64` (the upstream path is case-sensitive) by UTM revision,
runner architecture and build recipe, and checks that the sysroot contains
virglrenderer plus `EGL.framework` and `GLESv2.framework`.

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
build does not use this ccache wrapper. The workflow still builds the full UTM
dependency set; reducing that set requires a separate verified build recipe.

This sysroot is a build prerequisite, not a renderer implementation. The
RemoteGPU app must still add an iOS vtest adapter that renders to an
IOSurface-backed EGL surface and presents it through `CAMetalLayer` without a
framebuffer readback.
