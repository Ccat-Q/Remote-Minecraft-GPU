# Architecture

## Scope and evidence status (2026-10-28)

The Minecraft data flow is the approved **target**. Low-capability remote
iPhone single-frame display now works (A2.1); Minecraft does not. Ubuntu owns the real client/JVM/mods; iPhone owns GPU
execution/display/input/audio. Existing ADRs and the pinned renderer remain
unchanged; no video streaming or phone JVM is introduced.

| Status | Evidence / boundary |
| --- | --- |
| CI-verified | Linux virpipe/vtest/QUIC rendering, PRESENT/readback separation, native parser and resource/fence lifetime tests. Historical run links remain below; the Linux host uses software rendering, not the phone GPU. |
| Device-verified (user reports) | A2.0 `98e65d1`: real resource/shared-EGL/GPU snapshot/Metal isolation. A2.1 `3b5e80d`: actual Ubuntu frame over QUIC to iPhone18,3 / iOS 27.0.1, PRESENT 1/2, GPU-only snapshot/display and correct image, TRANSFER_GET=0. |
| Device-verified multi-frame | [7/12-frame records](evidence/a21-multiframe-2026-10-28/README.md), app `9ed016c` / `acce896`: distinct correct frames, >=120s live hold, GET=0, active disconnect cleanup returned. Same-process render reconnect still pending. |
| Implemented, device pending | [A3.1 single-slot begin/poll](a31-async-single-slot.md), independent GPU completion timer, bounded batch suffix and Keychain quick connection. Defaults to accepted sync mode; mock/CI results do not certify device behavior. |
| Known failed prerequisite | GLES 3.1/3.2 requests rejected (EGL 0x3004); GLES 3.0 works. Guest capset GLSL is 130, below 150. Actual Ubuntu GL 3.2 Core creation remains an unaccepted separate test. |
| Not implemented / accepted | A3 double buffering/overlapping production/memory budgets/ten-minute performance; Minecraft and input/audio/Modpack acceptance. |
| Candidate experiments only | MobileGlues + existing ANGLE Metal; MobileGL iOS interfaces; UTM MoltenVK with a suitable GL/Vulkan implementation. None replaces the renderer or has passed the guest gate. |

The completed [feasibility audit](../exa-results/remotegpu-feasibility-2026-10-12/audit.md)
is the research baseline. The blocker applies to the current capability
combination, **not to the entire remote-GPU architecture**. The
[next-stage plan](next-stage-plan.md) separates route A (PRESENT) from route B
(Minecraft graphics capability); A does not depend on B passing.
The audit's earlier recommendation to prioritize backend capability before
remote display is superseded by the user's approved independent routes; its
historical findings and evidence are retained unchanged.

## Data flow

```text
Minecraft Java 1.21.1 / LWJGL / GLFW
  -> Mesa virpipe + vtest winsys
  -> Unix socket
  -> RemoteGPU Linux proxy
  -> QUIC/TLS render stream
  -> RemoteGPU iOS vtest endpoint
  -> virglrenderer-ios -> ANGLE Metal -> IOSurface
  -> MTLTexture -> CAMetalLayer
```

The target `PRESENT` design emits from the Mesa vtest winsys presentation path,
never GLFW. The implemented hook includes its cumulative vtest byte offset. The Linux
proxy already waits until it has forwarded that offset, assigns
`after_sequence`, and emits the marker on the same QUIC stream. The iOS
endpoint already orders markers behind that sequence. The Mesa hook patch is
implemented and verified in its Linux presentation gate; the synchronous iOS
renderer adapter passed the single-frame A2.1 device gate.

Mesa waits for a local Unix datagram acknowledgement after sending the marker.
The proxy responds only once the marker is queued on QUIC. This prevents later
resource destruction from overtaking the marker and adds no phone/GPU round
trip. The phone must still retain presentation resources through its renderer
fence and Metal display submission.

The native decoder now supports resource pinning through UNREF and a dedicated
PRESENT fence. These mechanisms preserve resource lifetime and identify prior
GPU work; they do not snapshot framebuffer contents. The iOS frame adapter must
record its GPU-to-IOSurface copy at the ordered marker before consuming later
writes to the same resource. Its local completion poller must run independently
of incoming network messages. The native ANGLE context/caps diagnostic tests
initialization only; the separate synchronous snapshot/display adapter now
exists and passed A2.1 single-frame device acceptance. Its bounded waits are
NOT A3 asynchronous scheduling. The opt-in A3.1 implementation now uses
independent timer-driven producer/copy/Metal polls, but holds its single-slot
barrier through Metal completion. It is device-pending and is not the final
overlapped or double-buffered scheduler; see its dedicated implementation notes.

## Wire format

Every envelope is big-endian:

| Field | Size |
| --- | --- |
| magic (`RGP1`) | 4 bytes |
| type | 1 byte |
| flags | 1 byte |
| payload length | 4 bytes |
| payload | variable |

Types are `HELLO`, `VTEST_BYTES`, `PRESENT`, and `ERROR`. `VTEST_BYTES` starts
with an eight-byte sequence followed by original vtest bytes. A `HELLO` is the
first message sent by iOS and contains the pairing token. `PRESENT` contains
`frame_id`, `resource_id`, `level`, `layer`, dirty rectangle and
`after_sequence`.

## v1 safety boundary

The proxy reconstructs and validates legacy client vtest frames before they
reach QUIC. It rejects protocol negotiation other than vtest protocol 0,
mmap-able resources, blob resources, FD export, DRM sync, eventfd and unknown
commands. Before Minecraft is attempted, a trace determines whether protocol
0 can create a GL 3.2 Core context without an FD. If it cannot, the project
stops at this gate and expands Mesa's network-safe winsys; it must not pretend
a Unix FD is portable over QUIC.

The current Mesa compatibility patch selects that profile only when
`REMOTEGPU_VTEST_LEGACY=1` is present in the compute-client environment. This
is mandatory for every RemoteGPU launch; without it Mesa negotiates its newer
local-only vtest protocol and the proxy intentionally closes the session.

At the pinned Mesa revision, the virpipe winsys reads `VTEST_SOCKET_NAME`
and falls back to `/tmp/.virgl_test`. It does not honour `VTEST_SOCKET`.
The Linux gate uses the default path between Mesa and the proxy; deployments
can select another local path with `VTEST_SOCKET_NAME`. This was verified from
the pinned winsys source exported by CI.

## Independent validation routes

**A — Remote PRESENT:** reuse VirGL/ANGLE Metal, protocol 0, QUIC and the Mesa
hook. Add a modest GL 2.1 / GLSL 120 changing demo, subject to real guest
capability, without overrides. Preserve the existing Core/GLSL 150 tests.
Require Ubuntu-originated draws, GPU-only owned snapshots, frame ordering,
independent GL/Metal completion and zero normal-display full-frame CPU
readback. Begin with a small single-sample RGBA/BGRA 2D target, then a finite
changing sequence and 10 minutes. No initial 720p/30 requirement. A PASS is
remote display evidence, not Minecraft compatibility.

**B — Graphics capability:** investigate dispatch/context/iOS ARM64 interfaces;
build one isolated candidate probe at a time. Prioritize MobileGlues + ANGLE
Metal, then MobileGL, then UTM MoltenVK with a suitable compatibility layer.
Require executed GLSL 150 and feature tests, not overridden strings/caps.
Host-native desktop GL is not mandatory; the final Ubuntu Mesa guest must
create genuinely executable GL >= 3.2 Core. Library linking, local draw and
guest context acceptance are separate gates. No formal backend migration is
authorized by an exploratory probe.

**After A and B:** Vanilla 1.21.1 menu/world -> multiplayer -> input/audio ->
pinned NeoForge/individual Mods -> Modpack. Wi-Fi 720p/30 for 10 minutes is a
later target, followed by 5G tests, not a current result. The 2 vCPU/4 GiB host
is a constrained PoC environment, not a Modpack capacity claim.

The planned `gl_capability.c` correction separates baseline Core/GLSL/FBO/VAO/
instancing/sync acceptance from timer-query diagnostics and Mod-specific
requirements. Timer query is still mandatory in the existing code; it is not
fixed by this documentation change. Preserve explicit application readback
tests while requiring zero presentation-driven TRANSFER_GET.

## Retained CI and source evidence

The historical Linux transport/capability gate is verified in Actions with protocol 0: the remote
renderer exposes OpenGL 4.3 Core / GLSL 4.30 and the proxy records non-zero
traffic in both directions. It is a transport/capability proof only: it uses a
Linux diagnostic receiver and has no `PRESENT` path.

The Mesa presentation gate is now verified in [Linux PoC run 38186021966](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38186021966):
three GLSL 1.50/Core VAO triangle draws produce four ordered 64x64 presentation
events (including initialization), with zero TRANSFER_GET. A separate explicit
glReadPixels run returns the triangle's red center pixel with one TRANSFER_GET.
The Linux diagnostic endpoint inspects markers only and the CI host uses
software rendering; this does not establish iPhone hardware rendering.

The pinned iOS dependency recipe and iPhoneOS ANGLE/VirGL link gate passed in
[run 38185353942](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38185353942).
The device interop probe compiled and produced an unsigned iPhoneOS arm64 IPA
in [run 38188117904](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38188117904).
These are historical build/link records, not runtime acceptance. Later user
reports at that historical point confirmed local triangle/native caps only.
Subsequent A2.1 evidence above accepts remote draw replay; guest OpenGL 3.2
Core remains unaccepted on iOS and Minecraft is not started. Use
the newer external-EGL-fixed sysroot recorded below, not the earlier recipe.

All builds and compilation run in GitHub Actions. The Ubuntu server only runs
downloaded CI artifacts and target-environment checks; it does not build Mesa,
ANGLE, the proxy or the iOS application.

The native protocol-0 endpoint is implemented in `RGPUVTestSession` and shared
with a Linux diagnostic host. It supports context creation, capsets, resource
create/unref, transfers, submit and implicit fences using public virglrenderer
APIs; unsupported/FD-bearing extensions fail closed. CI checks parser safety
with AddressSanitizer/UBSan. A separate lightweight rendering gate downloads
the verified Linux bundle and compiles only the endpoint, avoiding a dependency
rebuild. The iOS EGL adapter and capability-only QUIC connection now exist.
Synchronous PRESENT snapshots now display real remote frames in A2.1;
opt-in A3.1 now adds single-slot asynchronous GPU/Metal polling, still awaiting
device acceptance. Overlapped scheduling and double buffering remain later work.

The shared native endpoint passed the actual GL/QUIC gate in
[run 38204899580](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38204899580)
at source `5285a18` on `feature/native-vtest-adapter`. It produces four ordered
PRESENT markers with zero TRANSFER_GET for normal swaps; explicit application
readback returns the red center pixel with one TRANSFER_GET. The sanitizer
contract tests and existing Go/Swift/Mesa checks passed in
[CI run 38204899558](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38204899558).
These are Linux software-renderer results, not iPhone hardware acceptance.

The resource pin/PRESENT-fence API also passed against the actual renderer in
[run 38206699446](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38206699446):
UNREF leaves a retained texture queryable, the captured fence completes, the
final display reference destroys the resource, and disconnect releases a
retired/pinned resource. The same run passes the zero-presentation-readback and
explicit application-readback triangle tests. It does not test framebuffer
snapshot/display ordering on iPhone.

The non-GBM external-EGL cleanup fix compiled into the pinned iOS sysroot and
passed the iPhoneOS link gate in
[run 38206257487](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38206257487).
The app includes a background native virglrenderer/ANGLE context/capset
diagnostic and report sharing. User reports confirm native initialization/caps
and local display, and also the GLSL 130 blocker. The app at `816bf85` passed
[CI run 38245169281](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38245169281)
and produced an IPA in
[run 38245180997](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38245180997).
Build success does not establish remote rendering. Follow
[the device acceptance checklist](../ios/DEVICE-TEST.md).

Retained pinned source evidence: Mesa
[`version.c`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/590bf21d918c86908d96d1f4590ecd25b9657171/src/mesa/main/version.c),
UTM VirGL
[`vrend_fill_caps_glsl_version`](https://github.com/utmapp/virglrenderer/blob/482f9d8b8c2d2288efa10a027116216909d2c226/src/vrend/vrend_renderer.c),
and ANGLE Metal
[`mtl_common.h`](https://github.com/utmapp/WebKit/blob/ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10/Source/ThirdParty/ANGLE/src/libANGLE/renderer/metal/mtl_common.h).
Device reports are user-supplied observations, not CI GPU execution evidence.

GitHub Actions caches Go modules/build output using `go.sum`, SwiftPM's build
and dependency directories using its resolved dependency manifest, the pinned
Meson tool virtual environment, and the Mesa/virglrenderer compiler output
using `ccache`. The cache namespace includes both pinned source revisions, the
Mesa patch set and ccache compiler configuration; it intentionally omits
generated Meson build directories, which contain absolute runner paths. Future
Mesa/ANGLE build workflows must likewise key compiler caches on pinned commits,
toolchain version and build flags; never key them only by branch name.

## Initial Linux PoC display scope

The downloadable Linux PoC artifact deliberately builds Mesa with the **X11**
platform only.  Its purpose is to prove the `virpipe → vtest → RemoteGPU`
transport path with the smallest useful OpenGL capability test; it is not yet
the Minecraft windowing environment.  Keeping Weston and Xwayland outside this
first gate avoids conflating a compositor/backend failure with a transport or
renderer failure, and avoids Mesa's unrelated `wayland-egl-backend` dependency.

Weston headless plus Xwayland remains the planned Minecraft integration stage,
after the remote renderer has passed the GL 3.2 Core and presentation gates.

## Hardening and remaining gates

Proxy HELLO/client-wait deadlines, peer cancellation, transport keepalive and
iOS byte/command admission budgets are implemented. A2.1-Final records local
per-PRESENT completion durations and quiet-hold checkpoints without readback.
Independent GPU completion, multiple bounded display slots and full GPU-wait/
RTT/shader-compilation/frame-stall attribution remain A3 work. Verify separately from the
two graphics routes, using task IDs in [next-stage-plan.md](next-stage-plan.md).
Reuse existing Actions caches/verified bundles. This plan does not authorize
DNS, deployment or production configuration changes.
