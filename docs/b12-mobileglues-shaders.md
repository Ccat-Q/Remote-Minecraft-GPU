# B1.2a isolated GLSL 150 shader / dynamic-output probe

Branch `experiment/b12-mobileglues-shader-probe`, after accepted B1.1 source
`d95d32be3d003f3c2c6c5a84b2f87132e4f6c7b2`.
[Actual B1.1 device evidence/provenance](evidence/b11-device-2026-10-29/README.md)
is retained. No formal renderer, VirGL/libepoxy dispatch, caps, ADR, DNS or
server deployment is changed. This is B1.2's first small batch, not the full gate.

## Isolation and provenance

Independent target `MobileGluesShaderProbe`, bundle
`org.remotegpu.experiments.mobileglues.shader`, display name **RemoteGPU B1.2a**.
Accepted B1.1 and formal RemoteGPU can remain installed. Shared bootstrap/context
code is reused, not copied. The B1.1 target does not compile Shader sources;
only the B1.2a target enables `RGPU_B12_SHADER_PROBE`.

The existing compatibility workflow selects the target/scope by the exact B1
branch, verifies the packaged bundle ID, source SHA, accepted B1.1 ancestor,
framework hashes and no GL hard-link contamination, and emits `b12a-*` artifacts.
The provenance JSON retains its `B11Provenance.json` resource filename for schema
compatibility, but explicitly identifies B1.2a/device-pending scope and the
accepted B1.1 SHA. Candidate recipe/pins are unchanged; framework/compiler caches
are used where branch-scoped Actions caches permit, otherwise the same pinned
candidate is built only in Actions. Accepted ANGLE sysroot run `40636888480` is
downloaded/verified, never rebuilt. All LGPL corresponding source is retained.

## Actual device test implemented (not yet accepted)

The accepted context/content-sharing/worker-migration checks run first on the
exclusive owner thread. On return to the root context, B1.2a then executes:

1. Resolve every added GL function through the checked frontend handle, validate
   exact image base and direct/proc equality. Raw backend query functions must
   belong to the exact installed GLESv2 image; no global/system dispatch.
2. Submit original GLSL `#version 150` vertex and fragment shaders unchanged.
   MobileGlues performs translation. Record the actual backend shader source
   using checked ANGLE `glGetShaderSource`; no candidate hook or App-side shader
   rewrite is introduced. The pinned frontend forwards this getter to GLES.
3. Compile/link; record both frontend and raw ANGLE statuses and full bounded
   compile/link logs. Empty logs are valid; absent source, excessive diagnostic
   source/log size (>16 KiB each), query errors or either failed status block.
4. Bind vertex attributes and fragment output. Create real VAO/VBO, capture UV
   and position attributes, unbind/rebind the VAO and draw two triangles.
5. Use a 16x16 RGBA8 FBO, a 2x2 nearest-filter texture, offset/scale/tint uniforms
   and interpolated UVs. Three cases change position, tint, texture contents
   and sampler unit (0/1/0). No shader replacement, clear-only or fixed-image
   shortcut is accepted.
6. Compare all 256 pixels per case against an independent integer rectangle/
   palette/tint oracle. Each rectangle covers 6x12 pixels; every background
   pixel is checked too. Fixed RGB tolerance +/-1, exact alpha. Report the first
   eight mismatches, total mismatch count, and all actual RGBA rows bottom-first.
7. Release shader/program/VAO/VBO/FBO/texture objects on success or failure before
   the owning context is closed; report GL/EGL errors. This is not leak profiling.

The local oracle uses three 16x16 readbacks plus B1.1's three 1x1 checks. These
small offscreen reads are diagnostic correctness evidence, not a remote display
or framebuffer-streaming implementation. No steady-state renderer path changes.
The one-shot test does not measure FPS, latency or sustained GPU performance.

## CI versus device boundary

Actions compiles the iOS ARM64 App and actual CPU oracle with ASan/UBSan. Oracle
fixtures verify geometry/texture-row/tint expectations, dynamic differences,
clear-only rejection and fixed tolerance. Source/provenance/isolation guards
verify the stage boundary. These do not compile/execute the shaders on iPhone.

Install the externally self-signed **RemoteGPU B1.2a**, leaving B1.1 installed.
Force-close/relaunch; tap **Run GLSL150 + Dynamic Output Probe**, once per process.
Share **Full Report**, including all source/log/pixel sections and any BLOCKED
result. No pairing token or server restart is needed. Preserve actual crash logs
if it crashes. Expected stages are B1.1 regression, then
`B12_STAGE GLSL150_VERTEX_FRAGMENT_DYNAMIC_FBO`, compile/link and three B12_CASE
results, followed by all cleanup calls. Do not infer a pass from version strings.

## Remaining gates

This batch covers representative vertex/fragment GLSL150, texture sampling,
uniforms/varyings and VAO/VBO/FBO operations only. Instancing, Depth/Stencil,
Blending, Texture Buffer, Sync/Fence and Geometry Shader remain separately
NOT TESTED, as do full GL3.2 limits/semantics and workload-specific Mod features.
Their later tests must distinguish GL3.2 requirements from optional/newer APIs;
no version or extension claims are added here.

Even a real B1.2a pass would not satisfy full B1.2, authorize formal VirGL
replacement, or pass Ubuntu guest GL3.2/GLSL150. B1.3 remains gated on necessary
local feature tests. No Minecraft, NeoForge or sustained-performance acceptance.

## First reproducible delivery (device pending)

- Source `c6c443facf52929f6caaa760f8bad675e4f4bde5`, branch `experiment/b12-mobileglues-shader-probe`.
- Accepted B1.1 evidence is committed separately at `29c5759` on `experiment/b11-mobileglues-probe`; no earlier device failure record was removed.
- [iOS Actions 40818346056](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40818346056) **passed**: candidate ARM64 build/link/exports, new App compilation, exact B1.2a bundle ID and scope, packaged framework hashes and no formal renderer/GL hard-link contamination.
- [Self-signable IPA artifact 12873800505](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40818346056/artifacts/12873800505), file `MobileGluesShaderProbe-unsigned.ipa`.
- [Diagnostics and LGPL corresponding source 12873227442](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40818346056/artifacts/12873227442): exact dependency pins, recipe, framework hashes, toolchain, actual compile/link logs and full modified candidate source.
- [CI 40818346038](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40818346038) **passed**: actual CPU pixel oracle with ASan/UBSan, retained B1.1 provider/metadata plans and native vtest/two-slot tests, 11 MobileGlues source/isolation/provenance tests, 32 Swift tests, Linux protocol/proxy and Mesa patch gates. The pixel oracle is not an iPhone or GLSL execution test.
- IPA SHA256 `133f36e34288edc23ce0562b0a01267aca09e3d7107951c2f923b7deac313cc5`; downloaded ZIP integrity, checksum and embedded source/run/scope verified.
- This branch rebuilt the same candidate recipe/source because its binary cache was unavailable. Its **new unsigned binary hash** is `6b3f2c2f280a715b8c40257e687e5d32f9ce9c920a5fff38ba9f57c5e711a07b`, not the accepted B1.1 artifact's `63f17c...`. All adapted source hashes and dependency pins match B1.1; do not claim the binaries are bit-identical or infer device acceptance from that match. The B1.1 regression must run in this new App too.
- ANGLE EGL/GLESv2 hashes remain exactly the accepted values; the sysroot was reused without rebuilding. No candidate feature, capability, version override or formal renderer change was made.

Runtime shader compile/link, translated sources, actual draw pixels, cleanup
and every B12_CASE still require the user's device report. No B1.2a device or
GPU-performance data is available yet. On failure retain Full Report/crash logs
and fix the concrete error before expanding the feature Gate.
