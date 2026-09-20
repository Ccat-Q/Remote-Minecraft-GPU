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
