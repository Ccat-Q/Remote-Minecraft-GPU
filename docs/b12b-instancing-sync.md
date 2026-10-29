# B1.2b instancing and same-context sync probe

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

## Implemented device tests (pending acceptance)

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
