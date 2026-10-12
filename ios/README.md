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

`RenderCoordinator.swift` is the planned bridge between transport and the future
Objective-C++ renderer adapter. Its adapter protocol requires a renderer fence
before an IOSurface may be submitted to `CAMetalLayer`.

The first implementation gate is a captured vtest trace replay plus the GL
3.2 Core capability report. Do not add Minecraft/JVM/launcher code here.

## Device interop probe

`App/` and `Renderer/RGPUIOSurfaceProbe` contain a one-shot device diagnostic:
ANGLE Metal draws a triangle into an IOSurface-backed EGL pbuffer, Metal wraps
the same IOSurface and samples it into a CAMetalLayer drawable with a vertical
coordinate correction. No pixel readback
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

The triangle probe has no network or vtest adapter. It uses host-only synchronous GPU
completion to isolate IOSurface interoperability. Async presentation fences,
remote resource lifetime management and guest capability testing belong to the
subsequent renderer adapter gate; the probe is not the production frame loop.

## Native vtest adapter gate

`Renderer/RGPUVTestSession` implements the protocol-0, no-FD command decoder
shared with `linux/tools/native-vtest-server.cpp`. It calls the public
virglrenderer API for context/resource creation, caps, uploads, application
readback, command submission and implicit fence polling. It accepts fragmented
and coalesced byte streams, including unpadded TRANSFER_PUT data. Caps replies
use the legacy byte-count convention; TRANSFER_GET replies are raw data.
Protocol negotiation and commands outside IDs 1–9 fail closed. Launch Mesa
with `REMOTEGPU_VTEST_LEGACY=1`. Zero-byte transfers are currently unsupported
and explicitly fail; this needs a measured compatibility decision if encountered.

The session must be created and destroyed inside the caller's initialized
virglrenderer lifetime, with all calls serialized. Its initialization cookie
must forward `write_fence` to `fenceCompleted`. One session owns one context and
its resource handles; it is not a multi-client resource namespace.

Actions runs sanitizer-backed decoder tests and a real GL -> QUIC -> native
decoder -> virglrenderer triangle/readback gate. The iPhone target compiles and
links and instantiates the same decoder for native/network capability probes.
Remote display still requires ordered resource retention at PRESENT,
GPU-to-IOSurface copy and a queue-local fence poller. Do not connect it to the existing frame
coordinator until that lifetime/presentation adapter is implemented.

For fast iterations, **Native vtest rendering gate** downloads a successful
Linux PoC bundle (latest successful main run by default), verifies its workflow and
presentation gate, and builds only this adapter. Mesa and virglrenderer are
not rebuilt. A full **Build Linux PoC** also exercises the native gate whenever
dependency pins or Mesa patches need changing. All compilation stays in Actions.
Specify `linux_run_id` to reproduce against a particular successful bundle.
If its artifact has expired, rerun the full Linux build; the gate fails with an
explicit instruction rather than silently using an unverified dependency build.

The native rendering gate passed at `5285a18` in
[run 38204899580](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38204899580).
Normal swaps emit four ordered PRESENTs without TRANSFER_GET; the separate
application-readback case retrieves the red triangle center pixel with one
TRANSFER_GET. This validates command execution by the shared native decoder on
Linux, not the still-unconnected iPhone renderer adapter.

## Native ANGLE context diagnostic

The app's **VirGL Context + Caps** button initializes the real pinned
virglrenderer with callback-v4 EGL context creation/sharing/destruction over
ANGLE Metal. It uses a 1x1 control pbuffer, feeds CREATE_RENDERER/GET_CAPS2/
GET_CAPS through the native decoder, and reports host strings and full base64
capsets. It does not run a guest OpenGL program or display a remote framebuffer;
capset availability is not acceptance of guest OpenGL 3.2 Core.

On the user's iPhone 17 / iOS 27.0.1, the native context/caps probe passed and
the host IOSurface triangle was visible, but vertically inverted. The display
probe now uses a Metal sampling pass instead of a direct blit; the corrected
orientation needs another device check. Reported host GLES is 3.0, and the
decoded capset-1 guest GLSL feature level is 130: the Minecraft capability gate
has not passed and must not be bypassed by version overrides.

Initialization and cleanup run on one serial background queue. The host triangle
probe is destroyed first, and both buttons are disabled until the native gate
finishes, preventing two diagnostics from sharing/terminating the same EGL
display or initializing virglrenderer concurrently. Record the report or error
after signing and installing the Actions-built IPA on a real iPhone.
Use a sysroot produced with the `--winsys` compatibility fix: the pinned fork
otherwise frees its borrowed external EGL wrapper only when GBM is enabled.
The checked patch frees the wrapper on non-GBM iOS too, without terminating the
caller's display. Repeated native diagnostics require this fixed sysroot.
The app packaging workflow checks the successful sysroot run's source recipe
for that fix and rejects earlier artifacts before downloading them.

`VTestSession` offers `retainForPresent`/`releaseFromPresent` and
`fenceForPresent`/`isFenceComplete`. A marker must arrive at a command boundary;
the adapter pins its resource and inserts a dedicated fence covering preceding
uploads as well as submits. Fence readiness refers to that fixed fence, not
all later GPU work. UNREF detaches a pinned resource but defers its destruction
until the final display reference is released. Reuse of a pinned retired handle
fails closed. The future frame loop must release after its GPU-to-IOSurface copy
completes, or tear down the session on failure; these APIs alone are not a
working asynchronous presentation adapter.

Retention protects lifetime, not framebuffer contents. The future adapter must
record the GPU-to-IOSurface snapshot at the ordered PRESENT marker, before
allowing later commands to overwrite that resource. Merely pinning a texture
and polling its fence while consuming later frames can display the wrong frame.
Fence completion/Metal display callbacks must also continue being serviced when
no further network messages arrive. Both conditions are frame-loop acceptance
requirements, not guarantees made by this diagnostic.

The unsigned iPhoneOS arm64 IPA build passed in
[run 38188117904](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38188117904).
Download its `ios-interop-prototype-*` artifact, extract the unsigned IPA, sign
and install it using your device provisioning method (iOS 17 or newer), then
tap **Render Probe**. Record the triangle's appearance and the capability report
or displayed error. The original host Metal/IOSurface path is user-confirmed
(with inverted Y). The sampling-pass correction and network guest GL 3.2 Core
gate remain pending device acceptance.

## Network capability endpoint

**Connect Capability Probe** starts the native iPhone vtest endpoint over one
QUIC stream. It requires normal iOS TLS trust and a pairing token. It rejects
PRESENT and all GPU readback in this diagnostic mode; it is not remote display.
Follow [the Ubuntu deployment/probe instructions](../docs/iphone-capability-probe.md).
Native calls are serialized and restore/unbind their EGL context on every
entry/exit, since DispatchQueue does not pin an OS thread. Local triangle,
native capset and network modes cannot overlap.

The native diagnostic now decodes the actual capset GLSL feature level and
reports a BLOCKED warning below 150. No capability bits or version strings
are overridden. Even a level >=150 does not prove a guest Core context exists.
