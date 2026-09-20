# iOS renderer dependency baseline

The first renderer dependency build is pinned to UTM commit
`9d00a54833184628c696bcbfafbf344cea566e59`. UTM is the reference because its
iOS sysroot build already combines ANGLE's Metal backend, libepoxy and its
Apple-specific virglrenderer fork.

Run **Build iOS renderer sysroot** in GitHub Actions. It invokes UTM's
`build_dependencies.sh -p ios -a arm64`, caches the resulting
`sysroot-ios-arm64` by UTM revision, and checks that the sysroot contains
virglrenderer plus `EGL.framework` and `GLESv2.framework`.

This sysroot is a build prerequisite, not a renderer implementation. The
RemoteGPU app must still add an iOS vtest adapter that renders to an
IOSurface-backed EGL surface and presents it through `CAMetalLayer` without a
framebuffer readback.
