# B1.2c isolated depth, stencil and blending probe

Latest verdict: **limited scope device PASSED** at `e989b4d`.
[Actual report summary, captured shaders and full provenance](evidence/b12c-device-2026-10-29/README.md).
Four complete outputs checked 1024 actual pixels / 0 mismatches; retained
regressions and cleanup passed. Not full B1.2, GL3.2 conformance, VirGL/guest or
Minecraft acceptance. The delivery-time pending instructions below remain historical.

Branch `experiment/b12c-mobileglues-raster-probe` retains accepted B1.1
`d95d32b`, B1.2a `c6c443f` and [B1.2b `f91d683`](evidence/b12b-device-2026-10-29/README.md).
Their context, shader and instancing/Fence regressions run before the new gate.
Independent target `MobileGluesRasterProbe`, bundle
`org.remotegpu.experiments.mobileglues.raster`, display **RemoteGPU B1.2c**.
No formal renderer, protocol, deployment, ADR or candidate provider recipe change.
MobileGlues remains pinned at `97558a69157b033b890958b1e49258c5b51a80c6`;
the verified ANGLE artifact is reused without rebuild. Provenance records actual
unsigned binary hashes, dependency pins and all accepted source ancestors.

## Actual device operations, not state-query-only tests

The shared checked frontend dispatch and shader source/status/log capture path
are reused. A GLSL150 vertex shader has dynamic depth; the fragment shader samples
a white texture and applies dynamic RGBA tint. A real DEPTH24_STENCIL8 renderbuffer
is attached to the 16x16 RGBA8 FBO. Storage bit counts, GL errors and framebuffer
completeness must succeed. Four complete output images are read and compared:

| Case | Actual draw sequence and expected distinguishing result |
| --- | --- |
| Depth LESS | Red base, rejected farther blue layer, nearer green center. Background 112, red 128, green 16 pixels. |
| Depth write mask | Draw green center with depth writes disabled, then yellow between green and base depth. Yellow must replace all 16 center pixels. |
| Stencil | Color-masked draw stores only low bits of 0xa5 using write mask 0x0f. EQUAL 5 draws red with INCR but write mask zero; NOTEQUAL 5 fills green. Exactly 72 red / 184 green pixels. |
| Separate blending | Blue background, red alpha 0.5 then green alpha 0.25. Separate RGB/alpha factors preserve alpha 255. Overlap RGBA (96,64,96,255), red-only (128,0,128,255), green-only (0,64,191,255). |

Fixed RGB +/-1 and exact alpha, 256 pixels per case / 1024 total, with actual
image hex dumps and mismatch counts. These are tiny local diagnostics only, not
remote display/readback streaming. No new glFinish or performance claim. Depth,
stencil and blend state is reset between cases and before releasing the new
renderbuffer; existing object and context cleanup follows on success or failure.
Shader translation, actual frontend/raw backend compile/link and provider checks
remain mandatory; version/profile strings do not grant capabilities.

The write-mask expectations follow Khronos [depth mask](https://raw.githubusercontent.com/KhronosGroup/OpenGL-Refpages/main/gl4/glDepthMask.xml)
and [stencil mask](https://raw.githubusercontent.com/KhronosGroup/OpenGL-Refpages/main/gl4/glStencilMask.xml)
semantics. Blend colors use [separate RGB/alpha factors](https://raw.githubusercontent.com/KhronosGroup/OpenGL-Refpages/main/gl4/glBlendFuncSeparate.xml).
This is representative coverage, not every depth function, stencil operation,
front/back stencil state, blend equation, format or multisample combination.

## Reproducible test procedure

All compilation runs in GitHub Actions. ASan/UBSan tests the exact CPU oracle
against four literal golden grids, boundary/region counts, invalid cases and
fixed tolerance mutations. Source guards verify real draw/state/attachment calls,
release paths, separate target, accepted-source chain and DEVICE_PENDING scope.
These CPU tests cannot execute or accept iPhone graphics semantics.

Self-sign and install **RemoteGPU B1.2c**, keeping accepted Apps installed. Launch
a fresh process, tap **Run Depth / Stencil / Blend Probe** once, then **Share Full
Report**. No Ubuntu server/pairing changes. Preserve any crash report. Expected:
all B1.1/B1.2a/B1.2b regressions, `B12C_STAGE DEPTH_STENCIL_BLEND`, actual shader
source/status/logs, packed attachment bits/FBO complete, four `B12C_CASE` records
with zero mismatches, all cleanup and the limited final PASS. Earlier stage-local
NOT TESTED lines refer to those stages, not an implicit final capability claim.

Texture Buffer, Geometry Shader, remaining required limits/semantics,
cross-context ordering, B1.3 integration and actual Ubuntu guest GL3.2 remain
unaccepted. No sustained performance, cancellation-safety or driver-leak verdict.

## Actual delivery

- Code `e989b4d86d70d1fa15fbbde119bcdac9287ac6ba`, branch
  `experiment/b12c-mobileglues-raster-probe`. B1.2b actual evidence was separately
  saved in `3cdfe97`; prior acceptance records remain intact.
- [iOS Actions 40821114364](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40821114364)
  **passed**: ARM64 compile, candidate exports/linkage, independent Raster target,
  bundle/scope/accepted ancestors, exact packaged framework hashes and isolation.
- [Self-signable IPA 12875005427](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40821114364/artifacts/12875005427):
  `MobileGluesRasterProbe-unsigned.ipa`. SHA256
  `f353153d2ac8e0fa138a1cbc8e6c6b1aef9b262d249e05a25e4cec281b548f9b`.
  Downloaded checksum and ZIP integrity verified; embedded source/run/scope and
  accepted B1.1/a/b source SHAs match this delivery.
- [Diagnostics and complete LGPL corresponding source 12874846437](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40821114364/artifacts/12874846437):
  actual build logs, linkage/export checks, dependency pins, toolchain, recipe,
  provenance and complete modified candidate/dependency source, not patch-only.
- [CI 40821114323](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40821114323)
  **passed**: four complete CPU golden grids under ASan/UBSan, retained B1.1/a/b
  tests, native vtest/double-slot tests, 14 MobileGlues source/isolation/provenance
  tests, 32 Swift tests, Linux proxy/protocol and Mesa patch gates. No local
  compilation; none of these results is device graphics execution.
- Actual unsigned candidate SHA256
  `ff8171a77c1dd8e41fce5ef6e1f0a7ec5c238eac91167d498c827be365949066`.
  All adapted source hashes match accepted B1.2b; rebuilt binary is not assumed
  bit-identical. Packaged EGL/GLESv2 hashes exactly match the accepted artifact.
- Formal `ios/Renderer`, `ios/App`, `ios/RemoteGPU`, candidate recipe and Provider
  bootstrap unchanged from accepted B1.2b. Only isolated Probe, CI and approved
  concise docs changed. No new Linux workload artifact is needed for this local,
  network-free iPhone batch.

The subsequent actual device report passed the four executed cases only, as
recorded above. Next: isolated Texture Buffer / Geometry and remaining functional
gates. Do not start B1.3 or elevate VirGL caps based on this limited acceptance.
