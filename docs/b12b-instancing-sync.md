# B1.2b instancing and same-context sync probe

Later audit caveat: earlier frontend GL0 is not proof of error absence because
the pinned getter suppressed errors. Actual pixels, raw shader/Fence observations
remain scoped evidence. [Strict retest boundary](b12d-blockers-and-retest.md).

Latest device verdict: **limited scope PASSED** at `f91d683`.
[Real report summary, translated source and full provenance](evidence/b12b-device-2026-10-29/README.md).
Three instance cases checked 768 pixels / 0 mismatches; three Fences actually
transitioned pending-to-complete and retired. No remaining/full guest gate follows.

Independent branch `experiment/b12b-mobileglues-features-probe`, following
accepted [B1.2a device evidence](evidence/b12a-device-2026-10-29/README.md) at
`c6c443facf52929f6caaa760f8bad675e4f4bde5`. No formal renderer, provider recipe,
version/capability claim, ADR, protocol or server deployment change.

Separate target `MobileGluesFeaturesProbe`, bundle
`org.remotegpu.experiments.mobileglues.features`, display **RemoteGPU B1.2b**.
Keep B1.1/B1.2a installed. Common startup/compile/draw/oracle/cleanup code is
reused; the new feature entry is compiled only for the B1.2b target. Provenance
records both accepted B1.1 and B1.2a SHAs, exact dependencies and binary hashes.
Same source/recipe may be rebuilt on the new branch; it is not assumed to be
bit-identical to earlier artifacts. B1.1 and B1.2a regressions must execute first.

## Implemented device tests (subsequently passed limited scope)

- Original GLSL150 VS uses `gl_InstanceID` to compute a 2x2 grid; flat integer
  varying carries the instance cell to the FS. `texelFetch` selects its palette
  entry. Original and actual translated source, frontend/raw ANGLE compile/link
  statuses and logs use the existing checked capture path.
- Actual `glDrawArraysInstanced`: 4, 2 and 0 instances. Each instance covers a
  distinct 6x6 rectangle in the 16x16 FBO. Full-grid expected coverage is 144,
  then 72, then 0 pixels. The two-instance case leaves upper positions visible
  as background, catching wrong counts; the zero case catches an unwanted draw.
  Palette/tint/sampler changes are checked too. This is not an attrib-divisor or
  indexed-instancing test; those APIs are not silently included in this verdict.
- Every instanced draw is followed by a real `glFenceSync` and `glFlush` on the
  same current root context. Repeated `glClientWaitSync(...,0,0)` calls are
  nonblocking GL observations. The diagnostic owner sleeps 1ms between pending
  observations and has a 5s deadline. Poll logs are sampled/bounded. No glFinish
  is added and no network/ACK is involved.
- Only ALREADY_SIGNALED/CONDITION_SATISFIED are completion; TIMEOUT_EXPIRED is
  pending, WAIT_FAILED/unknown statuses block. `glIsSync` verifies identity;
  `glGetSynciv(GL_SYNC_STATUS)` must confirm SIGNALED. Delete and confirm no live
  identity before pixel read. An RAII lease deletes any Fence on failure before
  its context is destroyed.
  These checks follow the Khronos [wait result definitions](https://raw.githubusercontent.com/KhronosGroup/OpenGL-Refpages/main/gl4/glClientWaitSync.xml),
  [identity query](https://raw.githubusercontent.com/KhronosGroup/OpenGL-Refpages/main/gl4/glIsSync.xml)
  and [deletion rules](https://raw.githubusercontent.com/KhronosGroup/OpenGL-Refpages/main/gl4/glDeleteSync.xml).
- After completion, read/compare all 256 pixels per case with an independent
  CPU oracle, retaining actual images and mismatch counts. Fixed RGB +/-1,
  exact alpha. Together with B1.2a this is six tiny local diagnostic reads, not
  a display/streaming implementation. GL objects are released on either path.

`observed_ms` is same-device monotonic polling-observation duration, not a GPU
timestamp or network/end-to-end latency. An immediately complete Fence is valid
but does not demonstrate the pending path, slow GPU, or in-flight cancellation.
This test does not prove cross-context GPU dependencies or steady-state async
scheduling. It is not the A3 scheduler and does not modify it.

## CI and device procedure

All compilation is Actions-only. C++ ASan/UBSan exercises the exact oracle and
completion-status classifier, including gaps, counts, palette, zero draws,
timeouts, invalid statuses and fixed tolerances. Source guards verify the draw,
Fence-before-read order, bounded deadline/cleanup, target and provenance scope.
These CPU fixtures are NOT GPU or shader device execution.

Install self-signed **RemoteGPU B1.2b**, relaunch a fresh process and tap
**Run Instancing + Sync Probe**, once per process, then Share Full Report.
No server restart or pairing. Preserve crash logs on a crash. Expect B1.1 and
B1.2a regressions, `B12B_STAGE INSTANCING_AND_SAME_CONTEXT_FENCE`, actual shader
source/status, three Fence/retirement records, three B12B_CASE zero-mismatch
records, and all cleanup. Stage-local earlier NOT TESTED lines precede this test;
the final verdict and actual executed records determine B1.2b's scope.

Depth/Stencil, Blending, Texture Buffer and Geometry Shader remain NOT TESTED.
Full GL3.2, necessary workload limits/semantics, B1.3 VirGL/Ubuntu guest GL3.2,
Minecraft/NeoForge, performance and driver-leak profiling remain unaccepted.
No successful result may be inferred from version/profile strings or CI.

## Reproducible delivery (subsequently passed limited device scope)

- Source `f91d6838b1534a65a8c7e6eecc4830a2e47c572d`, branch `experiment/b12b-mobileglues-features-probe`.
- Accepted B1.2a device evidence is a separate commit `362f848` on `experiment/b12-mobileglues-shader-probe`, preserving full provenance and actual translated shaders. Earlier failures were not removed.
- [iOS Actions 40819548554](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40819548554) **passed**: ARM64 candidate build/link/export checks, independent Features App build, exact `.features` bundle/scope and accepted-source chain, unsigned framework hashes and no formal GL/provider hard-link contamination.
- [Self-signable IPA artifact 12874211415](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40819548554/artifacts/12874211415), file `MobileGluesFeaturesProbe-unsigned.ipa`.
- [Actual build diagnostics/LGPL corresponding source 12873484748](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40819548554/artifacts/12873484748), with pins, recipes, complete provenance, toolchain, compile/link logs and modified candidate source.
- [CI 40819548714](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40819548714) **passed**: actual instance oracle/status classifier ASan/UBSan, retained B1.2a oracle, B1.1 policy tests, native vtest/double-slot tests, 12 MobileGlues source/isolation/provenance tests, 32 Swift tests, Linux proxy/protocol and Mesa patch gates. None substitutes for iPhone execution.
- IPA SHA256 `a7c431d73f030fef1ba84e72c0eface9f11db630101fc3bca45e150135d1ab68`; downloaded checksum, ZIP integrity and embedded source/run/accepted B1.2a SHA verified.
- Rebuilt unsigned candidate framework SHA256 `6ecf6f14f3a79cfedfe288cce5d61d8d5c1bf563ca160aa4216fb008b0486dce`; source pins and every adapted source hash match the accepted B1.2a recipe, but the binaries are NOT claimed bit-identical. ANGLE EGL/GLESv2 hashes remain exactly the accepted values and were reused without rebuilding.
- Changed: independent target/UI/scope, common draw runner extended with an isolated instancing/Fence entry, new oracle/status-policy header and tests, CI/packaging selection, concise docs. Formal `ios/Renderer`, `ios/App`, `ios/RemoteGPU` are unchanged from accepted B1.2a.

The user's subsequent actual report supplied shader compilation, 4/2/0 pixel
results, pending/completed Fence states, retirement and cleanup success. See
the evidence above. The observed polling durations are not GPU/performance data.
