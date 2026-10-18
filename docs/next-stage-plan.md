# Next stage: independent PRESENT and graphics capability experiments

Approved scope: 2026-10-13. This document translates the completed audit into
implementation tasks; it does not repeat the feasibility study. Existing ADRs,
renderer selection, source pins, protocol 0, ordered QUIC stream, tests and
CI evidence remain intact. **Only documentation/interface investigation is
completed in this round. All implementation and device gates below are pending.**

## Order and isolation

1. Implement route A's small remote draw/snapshot/display loop first.
2. Bring up one isolated MobileGlues + current ANGLE candidate probe (route B).
   If interface/feature gates block it, record the missing interfaces and
   required changes before considering MobileGL, then the MoltenVK candidate.
3. Implement hardening tasks in separately tested changes; do not attribute
   their failures to graphics capability. Budgets/completion needed for safe
   route A must be present before its sustained/device-network acceptance.
4. Only after A and the final guest capability gate pass, start Minecraft.

Routes are independent in acceptance, not permission to build three complete
backends simultaneously. A can pass while B remains blocked. B's libraries,
global dispatch and initialization must not contaminate A's baseline process.
No DNS/deployment/production changes or formal backend migration occur here.

## Route A: Remote PRESENT PoC

### Reusable code and actual interface gaps

| Existing interface/file | Reuse | Missing integration |
| --- | --- | --- |
| `patches/mesa/0002-remotegpu-present.patch` | Winsys resource/rectangle, cumulative vtest byte offset, local ACK | No new Mesa opcode/GLFW hook needed; retain opt-in behavior and Linux tests. |
| `internal/proxy/bridge.go`, `present.go` | One ordered QUIC stream, sequence and PRESENT marker ordering | Phase deadlines/cancellation and diagnostics are separate hardening work. ACK means queued, not GPU complete. |
| `RGPUVTestSession.hpp/.cpp` | `feed`, `atCommandBoundary`, `retainForPresent`, `releaseFromPresent`, `fenceForPresent`, `isFenceComplete` | Associate immutable fence/resource/snapshot tickets with frame IDs. Pinning preserves lifetime, not content. |
| `RGPUVirglProbe.mm::ANGLEHost` | External display, renderer callbacks/shared-context creation, restore/unbind, teardown | Factor reusable ownership without breaking existing diagnostics; expose controlled presentation context access. |
| Public `virgl_renderer_resource_get_info` | GL texture ID, dimensions, format and orientation flags | Validate session ownership, 64->32-bit handle range, supported target/mip/layer/sample count; no raw-ID assumptions. |
| `RGPUIOSurfaceProbe.mm`, `OrientationDisplay.metal` | IOSurface/CVPixelBuffer/MTLTexture allocation and orientation-correct sampling | Extract shared allocation/display utility; existing probe owns an independent context and cannot see VirGL textures by assumption. |
| `RemoteGPUFrameOrder`, `RenderCoordinator.swift` | Envelope sequence/PRESENT parsing | Replace packet-only draining with staged snapshot admission and independent completion; never submit later writes before snapshot is safe. |
| `QUICRenderConnection.swift`, `NativeCapabilityConnection.swift` | TLS/pairing and serialized native ingress pattern | Add bounded receive admission and a separate display session. Capability-only mode continues rejecting PRESENT. |

The pinned UTM resource API also has conditional Metal-native-handle support.
It depends on native-share flags, scanout bind, build options and resource
shape; protocol-0 window resources are not guaranteed to satisfy those
conditions. **First use GL texture -> IOSurface GPU copy**, not an assumed
MTLTexture export. Keep the approved IOSurface route.

### A1 — low-capability Ubuntu draw producer

Proposed new file: `tests/gl_remote_present.c`; reuse wrappers/harness in
`deploy/`, `tests/mesa_present_gate.py`, `linux/tools/native-vtest-server.cpp`.
Compile through `build-linux-poc.yml` or a lightweight artifact-reusing job in
`native-vtest-gate.yml`; do not rebuild Mesa solely to compile the new demo.

- Request GL 2.1 compatibility, use GLSL 120, VBO/attributes and uniforms.
  Avoid `gl_VertexID`, Core-only VAO assumptions and GLSL 150. If real context
  creation fails, fail visibly; never force GL/GLSL version or use llvmpipe in
  the compute application as fallback.
- Small 64x64 or 256x144 single-sample target; animate position/color with an
  application-frame pattern encoded by Ubuntu. Emit frame logs, then stop
  traffic after a final frame without immediately closing the display session.
- Keep the old `gl_present.c` Core/GLSL 150 and explicit-readback tests unchanged.
  Apply virpipe environment only to the demo after Xvfb starts.
- Acceptance: real SUBMIT_CMD traffic, ordered PRESENT markers, changing
  triangle through the Linux native adapter and zero normal-display
  TRANSFER_GET. This CI test alone does not prove phone display.

### A2 — resource-to-IOSurface adapter and conservative snapshot state machine

Proposed `ios/Renderer/RGPURemotePresent.h/.mm` and a reusable IOSurface target
helper; touch `RGPUVirglProbe.mm`, `RGPUVTestSession.*` only as required,
`RemoteGPU-Bridging-Header.h` and `ios/project.yml` for integration. These are
proposed filenames, not existing implementations.

Two paths were considered: fully pipelined cross-context GPU/event ordering
(better throughput, more unverified interop) versus pausing later command
execution until a local GPU snapshot is complete (simpler, lower throughput).
**Use the latter for the first correctness PoC.** It adds local GPU waits, not
a new network ACK round trip. TODO: replace with proven cross-API GPU dependency
chaining only after frame-content/lifetime tests pass and profiling justifies it.

```text
ordered PRESENT at complete vtest boundary
  -> validate resource/subresource; retain source; capture producer fence
  -> pause subsequent vtest execution (bounded network admission continues)
  -> independent poll: producer fence ready
  -> shared presentation context: GPU copy into free, owned IOSurface slot
  -> GL copy fence + flush; keep later source writes paused
  -> independent poll: copy fence ready
  -> release source pin; resume ordered vtest execution
  -> Metal samples snapshot and presents
  -> Metal completion: recycle IOSurface slot on renderer queue
```

Critical invariants:

- Copy context must share the producer's EGL share group. Producer completion
  is necessary before reading its texture; copy completion is necessary before
  a later producer write/UNREF can race the copy in another context. A fence
  captured before the copy does not prove the copy has finished.
- Isolate copy-context state from VirGL's cached GL state. Make current/unbind
  explicitly on every queue entry; a serial DispatchQueue is not one OS thread.
  Treat share failure as an error, not a reason for CPU readback.
- V1 supports color 2D level 0/layer 0, single sample and a format whitelist.
  Record target/sample metadata from resource creation if public get_info does
  not expose it. Full-resource snapshots are acceptable for this PoC; dirty
  rectangles are validated, not a requirement for optimization. Unsupported
  shapes fail explicitly; no bogus scaling/format interpretation.
- Select orientation from resource flags and an asymmetric test pattern; the
  local probe's fixed vertical flip is not automatically correct for every
  VirGL resource. Avoid double flips, BGRA/RGBA swaps and implicit sRGB changes.
- Snapshot contents are owned independently of the source. Resource refs can
  release after the completed copy; surface/texture refs release only after
  Metal completion. All unwind/UNREF/disconnect/error paths balance ownership.
- No normal-display glReadPixels, TRANSFER_GET, CPU pixel locks/copies or video
  encoder. Legitimate application readback stays supported in the general
  renderer profile; capability-only mode remains intentionally stricter.

### A3 — independent completion, bounded scheduling and display mode

Touch `RenderCoordinator.swift`, `Protocol.swift`, `QUICRenderConnection.swift`,
`App/RemoteGPUPrototype.swift`; add a dedicated remote-display session rather
than silently repurposing **Connect Capability Probe**.

- A timer/poller and Metal completion callbacks run independently of incoming
  packets and marshal state back onto the renderer queue. Use nonblocking
  fence checks, no steady-state `glFinish`/`waitUntilCompleted` loop.
  Existing synchronous native BUSY_WAIT/shader compilation can still delay a
  serial queue; bound/report these stalls and test stop/completion behavior.
  An independent driver is not a promise that all native calls are asynchronous.
- Start with two owned display slots. If both are busy, stop advancing past the
  next PRESENT and propagate receive backpressure. Do not overwrite a slot
  still sampled by Metal. Initial finite-sequence acceptance does not drop
  frames; any later coalescing policy must be explicit and tested.
- Budget inclusive queued + in-flight command bytes/work, parser buffers,
  pending PRESENTs and GPU resources; cancellation must stop admission before
  draining/cleanup. Do not solve overload by dropping arbitrary GPU commands.
- Gate UI modes to prevent concurrent local/native/remote renderer ownership.
  Disconnect tears down session state; transparent Minecraft recovery is not
  part of this PoC.

### A4 — acceptance and regression suite

Extend `ios/Tests/RemoteGPUProtocolTests.swift` with deterministic fake-clock/
fence/surface-scheduler tests; retain `tests/native_vtest_lifetime.cpp` and add
snapshot/rewrite tests to the native Linux harness where applicable. Device
checks remain separate from CI mocks or Linux software execution.

Required cases: last frame after traffic stops; delayed producer/copy/Metal
completion; repeated writes to one source; UNREF and ID reuse; malformed
resource/rect; two-slot saturation; disconnect during each stage; balanced
cleanup; no later frame overtakes an earlier accepted frame. Correlate
application frame patterns with logs: initial frontbuffer flushes mean PRESENT
ID is not necessarily the application's frame number.

Device acceptance progresses from a finite correctly changing remote triangle
to 10 minutes without corruption/crashes or sustained resource growth, with
zero presentation readback. Preserve screenshots/OS recordings and full logs.
Initially record achieved FPS/stalls without requiring 720p/30. Do not mark A
PASS from the local probe, cap initialization or marker-only receiver.

## Route B: Graphics Backend Capability PoC

### Source/interface investigation completed in this round

These are **inspection snapshots**, not new official dependency pins or build
results. No broad feasibility research was repeated.

| Candidate snapshot | Reusable interfaces | Concrete interface blockers / work |
| --- | --- | --- |
| MobileGlues `97558a69157b033b890958b1e49258c5b51a80c6` | `egl/egl.cpp` exports create/make-current/proc lookup, tracks frontend desktop contexts over backend ES; `egl/context.cpp` tracks TLS/share groups; `gl/shader.cpp` invokes `GLSLtoGLSLES`, includes sampler-buffer emulation path | Apple CMake framework names differ from our EGL/GLESv2 packages; non-MSVC GNU `-Bsymbolic-functions` is not an Apple link recipe. Apple loader uses a sentinel `dlsym` lookup rather than explicit backend handles; static constructor runs `proc_init` and creates a bootstrap display. Need deterministic provider/init ownership and actual feature tests. |
| MobileGL `08124c99f12ab2283cc15e4dc64ea972ecbd49c1` | Explicit `MOBILEGL_IOS`, optional Vulkan-library build input, frontend EGL exports/state, MetalLayer window backend and DirectGLES implementation | iOS loader expects `libtinygl4angle.dylib` when not using its Android-style ANGLE sonames; it is not our embedded EGL.framework. Frontend EGL handles/state wrap backend ownership, rather than simply borrowing our context. Need provider bridge, share/context tests and actual IOSurface forwarding. |
| UTM MoltenVK `2974cbbbd42593eeeaf993d954702f74ae09a239` | UTM pinned dependency recipe; geometry/transform-feedback code inspected in the audit | Requires a selected GL/Vulkan implementation, feature-execution proof and resource interop. Existing sysroot excludes it. No automatic Venus migration or inference from advertised Vulkan version. |

Source links:

- MobileGlues [CMake](https://github.com/MobileGL-Dev/MobileGlues/blob/97558a69157b033b890958b1e49258c5b51a80c6/MobileGlues-cpp/CMakeLists.txt),
  [EGL frontend](https://github.com/MobileGL-Dev/MobileGlues/blob/97558a69157b033b890958b1e49258c5b51a80c6/MobileGlues-cpp/egl/egl.cpp),
  [context state](https://github.com/MobileGL-Dev/MobileGlues/blob/97558a69157b033b890958b1e49258c5b51a80c6/MobileGlues-cpp/egl/context.cpp),
  [backend loader](https://github.com/MobileGL-Dev/MobileGlues/blob/97558a69157b033b890958b1e49258c5b51a80c6/MobileGlues-cpp/gles/loader.cpp),
  [shader translation](https://github.com/MobileGL-Dev/MobileGlues/blob/97558a69157b033b890958b1e49258c5b51a80c6/MobileGlues-cpp/gl/shader.cpp).
- MobileGL [CMake](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/CMakeLists.txt),
  [backend loader](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/MobileGL/MG_Util/BackendLoaders/OpenGL/Loader.cpp),
  [EGL frontend](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/MobileGL/MG_Impl/EGLImpl/EGLImpl.cpp),
  [DirectGLES context attachment](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/MobileGL/MG_Backend/DirectGLES/BackendObject_DirectGLES.cpp).
- Pinned [libepoxy dispatch](https://github.com/utmapp/libepoxy/blob/bf98587477fe68d07b93319ece7b40a7d0e2eabe/src/dispatch_common.c)
  selects iOS EGL/GLES frameworks and a desktop OpenGL library path. Context
  callbacks alone do not redirect all VirGL GL calls into a candidate frontend.
- Pinned [UTM MoltenVK](https://github.com/utmapp/MoltenVK/blob/2974cbbbd42593eeeaf993d954702f74ae09a239/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm).

### B1 — first candidate: isolated MobileGlues/ANGLE device target

Proposed `ios/Experiments/MobileGluesProbe/`,
`tools/ci/prepare_mobileglues_probe.py` (checked source adjustments) and
`.github/workflows/build-ios-compatibility-probe.yml`. Keep production sysroot
and app target untouched. A separate signed probe avoids a candidate static
constructor or duplicate GL/EGL symbols affecting route A at app startup.

1. Actions ARM64 build/link: reuse verified ANGLE sysroot; compile only the
   pinned candidate and its needed shader dependencies. Adapt Apple linker
   flags/framework names and explicit initialization/resolver in the isolated
   recipe. Publish symbol/provider and dependency manifests; actual link is
   the verdict, not the existence of `__APPLE__` source branches.
2. Prove dispatch: frontend GL/EGL exports resolve to MobileGlues; its backend
   GLES/EGL pointers resolve to the pinned ANGLE. Check create/share/make-current/
   unbind/destroy and cross-thread reattachment; reject recursion or accidental
   platform OpenGLES/Desktop OpenGL loading. Never rename frameworks to trick
   global lookup into an unverified provider chain.
   Add a named resolver/explicit bootstrap rather than depending on dyld image
   order; compiler/link fixes alone do not resolve provider ownership.
3. Execute a GLSL 150 vertex/fragment program with varying inputs; capture its
   translated shader/compiler log and compare output to a reference pattern.
   Test FBO, VAO, instancing, samplerBuffer emulation, depth and real sync.
   Geometry and full desktop semantics need dedicated execution tests;
   an unsupported stage blocks the full guest goal even if Vanilla-like draws
   work. Missing required features are FAIL/BLOCKED, not SKIP-as-PASS.
4. **Only after local execution:** an isolated virglrenderer/libepoxy build
   routes GL dispatch to the frontend and retains callbacks for its context
   provider. Do not just remove `VIRGL_RENDERER_USE_GLES` and hope dispatch works.
   Compare candidate vs baseline init/resource/shader/fence traces.
5. Connect Ubuntu Mesa in capability mode and require actual GL 3.2 Core context,
   shader/draw and required feature behavior. No modified GL_VERSION,
   GLSL_VERSION, custom advertised version or cap-bit override is acceptance.

### B2 — MobileGL fallback investigation, not a second backend implementation

Reuse its explicit iOS CMake/loader/EGL interfaces and small integration-test
scenarios where practical. Resolve the tinygl4angle/provider dependency before
building a probe. Its frontend context handles/resource IDs may be virtual;
do not pass them to raw ANGLE or assume VirGL `tex_id` directly identifies a
native texture. Need a supported copy/export path through the same frontend
or an explicit native-resource adapter. Validate multiple VirGL contexts,
sharing and ownership with the existing native session pattern.

Work is more than a library-name swap: build/provider bridge, dispatch
isolation, context mapping, shader/feature tests, then renderer integration.
If a missing interface needs substantial new implementation, report it and
the bounded work before proceeding. Do not replace the transport/game design.

### B3 — MoltenVK fallback, after a GL implementation is selected

Reuse UTM fork/source pins and Actions cache structure. First execute its
feature tests on the phone, then validate the selected GL/Vulkan compatibility
layer's full requirements. Choose a local-host compatibility chain that can
retain VirGL when viable. Venus/shared-memory network work remains separately
unapproved; no candidate result silently authorizes it. Do not implement a
standalone Vulkan backend without specifying how it provides guest GL semantics.

## Hardening and diagnostics tasks (all implementation pending)

| ID / files | Planned change | Acceptance / isolation |
| --- | --- | --- |
| H1: `tests/gl_capability.c`, `tests/README.md`, existing gate workflows | Separate baseline Core/GLSL/FBO/VAO/instancing/sync from optional timer query and Mod requirements; add executed shader/draw tests where appropriate | Timer-query absence alone does not fail the baseline; missing required Core/GLSL still fails. Keep old results labelled as the former stricter test, preserve regressions and do not bypass GLSL 130. |
| H2: `internal/proxy/bridge.go`, `bridge_test.go`, CLI config | Explicit HELLO deadline, local-client wait deadline, session/server cancellation linked to QUIC disconnect; clear phase deadlines correctly | Incomplete HELLO, phone disconnect before Unix client, absent client, auth failure, shutdown and fresh reconnect terminate promptly without consuming the next client in a stale session. No firewall/TLS/deploy edits. |
| H3: `QUICRenderConnection.swift`, remote session/coordinator, `Protocol.swift`, `RGPUVTestSession.*` | Admission backpressure; inclusive queued/in-flight byte/work budgets; bounded parser/PRESENT/GPU-resource state and two display slots | Slow GPU cannot grow queues indefinitely; bounds errors/stop are explicit. Pause receiving rather than dropping GPU state commands. Test accounting after every failure/cancel; mock tests do not establish hardware behavior. |
| H4: `internal/diagnostics/collector.go`, tests, native/probe/coordinator metrics | Measured QUIC RTT from available transport tracing, local fence wait, shader compile/link observations, frame-stall reason/duration and queue/resource high-water marks | Separate QUIC RTT, application round-trip waits, queue delay and GPU fence latency. A fence wait is not an elapsed-time GPU query. Shader data unavailable at a layer is labelled unavailable, not inferred from SUBMIT duration. Local monotonic timings must not be subtracted across unsynchronized hosts. |

For route A, choose bounded limits at implementation time and record them in
the report (pending-byte budget must admit the largest accepted message).
Instrument without changing frame order or synchronizing every draw. Diagnostics
must not add normal framebuffer readback. Preserved synthetic/mock and actual
renderer tests make hardening independent of candidate library behavior.

## Build, evidence and exit conditions

All compilation/testing that builds code runs in GitHub Actions. The Ubuntu
host only uses downloaded artifacts. Reuse verified Linux bundles and the
external-EGL-fixed iOS ANGLE sysroot; keep existing compiler/module/source caches.
Candidate cache keys include source/submodule pins, toolchain, recipe and flags;
do not poison the formal renderer cache or cache generated runner-path builds.
If an artifact expires, rerun its verified workflow in Actions, not locally.

Every acceptance report identifies app/source/dependency SHA, device/OS,
context/provider, expected vs actual frame/feature output, traffic/readback
counters, waits/budgets and errors. Preserve all previous run links; append new
evidence with precise scope. CI mocks, Linux software rendering, iOS linking,
local device rendering and end-to-end guest rendering remain separate labels.

Route A stops at resource sharing/copy/ordering failures without a CPU fallback;
route B stops at missing provider/context semantics or unimplemented features
without capability spoofing. Neither failure deletes previous results. Formal
renderer/ADR changes require explicit approval. Minecraft and Modpack success
remain later goals, not implications of either isolated triangle probe.
