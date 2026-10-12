# iOS renderer target

GitHub Actions builds the Swift protocol package on macOS. The complete renderer
target is also built only in GitHub Actions once its pinned C/C++ dependencies
are added; do not compile it locally. The pinned GitHub Actions-only sysroot
procedure is documented in [DEPENDENCIES.md](DEPENDENCIES.md).

The implementation must embed the pinned `virglrenderer-ios` and ANGLE Metal
dependencies, render to an IOSurface-backed EGL surface, then wrap that
IOSurface as an `MTLTexture` for `CAMetalLayer` presentation. It opens one
outbound QUIC stream, first sends `HELLO`, and then processes `VTEST_BYTES` and
ordered `PRESENT` envelopes from `Protocol.swift`.

`QUICRenderConnection.swift` uses `NWProtocolQUIC` with the `remotegpu/1` ALPN
and normal iOS trust evaluation. Deploy a certificate trusted by the iPhone;
the client does not contain an insecure trust-all development bypass.

`RenderCoordinator.swift` is the only bridge between transport and the future
Objective-C++ renderer adapter. Its adapter protocol requires a renderer fence
before an IOSurface may be submitted to `CAMetalLayer`.

The first implementation gate is a captured vtest trace replay plus the GL
3.2 Core capability report. Do not add Minecraft/JVM/launcher code here.

## Device interop probe

`App/` and `Renderer/RGPUIOSurfaceProbe` contain a one-shot device diagnostic:
ANGLE Metal draws a triangle into an IOSurface-backed EGL pbuffer, Metal wraps
the same IOSurface and blits it into a CAMetalLayer drawable. No pixel readback
or CPU framebuffer copy is used. The device displays host GLES/GLSL/renderer
strings. These host strings do not prove guest OpenGL 3.2 Core support.

Run **Build iOS interop prototype** in GitHub Actions with the run ID of a
successful **Build iOS renderer sysroot** run that passed the iPhoneOS link
gate. The prototype workflow also starts automatically when that dependency
workflow succeeds on main. It reuses those artifacts, builds for iPhoneOS arm64 and
publishes an unsigned IPA. It needs external device signing before installation;
the repository contains no signing identity. Launch it on an iPhone and tap
**Render Probe**; expect an orange triangle on a dark background and a capability
report. Failures are shown in the report.
The IOSurface is allocated through CoreVideo's public IOSurface-backed
CVPixelBuffer APIs. The probe never locks or reads the pixel buffer's CPU base
address; it keeps the buffer alive while EGL and Metal use the shared surface.

This probe has no network or vtest adapter. It uses host-only synchronous GPU
completion to isolate IOSurface interoperability. Async presentation fences,
remote resource lifetime management and guest capability testing belong to the
subsequent renderer adapter gate; the probe is not the production frame loop.
