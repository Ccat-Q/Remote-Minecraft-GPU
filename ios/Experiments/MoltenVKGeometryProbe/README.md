# Isolated UTM MoltenVK Geometry Probe

Status: source implementation; Actions and iPhone execution **PENDING** until linked
in [the experiment record](../../../docs/moltenvk-geometry-probe.md).

This app links only the pinned UTM MoltenVK framework. It does not load ANGLE,
MobileGlues, epoxy, virglrenderer, QUIC or RemoteGPU's display code. No ADR change.
All compilation, shader validation and Python tests run in GitHub Actions only.

Dependency: `utmapp/MoltenVK@2974cbbbd42593eeeaf993d954702f74ae09a239`.
No source patches or capability overrides. Its exact external revisions, sources,
licenses, shader source/SPIR-V/disassembly, tool versions, binary SHA and app SHA
are preserved with the Actions artifacts. This is not an upstream conformity claim.

## Important source blocker

The pin implements VS→Metal object and GS→Metal mesh shaders, but reports zero
Geometry limits. The app checks the actual device-reported limits before each GS
pipeline. A zero limit means **BLOCKED / NOT RUN**, not permission to submit an
invalid Vulkan shader. Basic VS/FS control is executed separately and cannot count
as Geometry success. Newer fork HEAD inspected on 2026-10-30 retains these zeros;
no unrecorded dependency upgrade is made.

## Fixtures

- C0: fullscreen VS/FS red then green, full 32×32 pixel checks and fences.
- G1: one triangle's position/varying feeds GS generation of two separate quads.
- G2: triangle/line/point inputs to triangle strips; point input to lines/points.
- G3: PrimitiveID input, two invocations, interpolated color varying, gl_Position.
- Every attempted GS case repeats three vertex/uniform parameter revisions (G4)
  using persistent resources, with bounded per-submission fence completion before
  host read, update/reuse and eventual release (G5). No global device/queue idle.
- X1: GS transform feedback; eight ordered position/color records and pixel oracle.
  Non-GS transform feedback, streams/counters and full extension coverage NOT_TESTED.
- I1/I2: GS non-indexed/indexed indirect draw, independently counted; the pinned
  implementation explicitly does not execute these paths. A blocked prerequisite
  never becomes a skip-PASS.

The generated SPIR-V entry points are checked to be `Geometry`, not a vertex
substitute. These are representative tests, not CTS, all possible topologies,
maximum-limit stress, overlapping GPU submissions, cancellation, leak or performance
acceptance. Line endpoint rules may require diagnosis from retained actual/oracle
images; do not loosen an oracle to hide a driver mismatch.

## iPhone steps

1. Download the IPA and SHA256SUMS from the linked successful Actions run. Verify
   SHA before external signing. Resigning changes bytes; original hash scope remains
   unsigned. Install with your normal signing method; separate bundle identifier
   `org.remotegpu.experiments.moltenvk.geometry` keeps both accepted apps installed.
2. Open **RemoteGPU Geometry**, keep it foreground, tap **Run Strict Geometry Probe**
   once. No server connection or network permissions are needed.
3. Tap **Share Report + Features + Images**. Send `report.txt`, `features.json`,
   `Provenance.json`, all actual/expected PNGs and any `xfb.bin` files, including
   failures. Files are also in Files → On My iPhone → RemoteGPU Geometry → GeometryReport.
4. After a crash, relaunch and share the persisted partial report *before* rerunning;
   collect an iOS crash report if available. Relaunch to repeat a completed run.

The app saves each log entry promptly. It does not bundle Khronos validation layers;
if the runtime cannot enumerate that layer, validation is **NOT_AVAILABLE/NOT_TESTED**,
not "zero validation errors means clean". MoltenVK debug-utils diagnostics are logged
separately. Functional output evidence and validation coverage remain separate gates.

Readback/PNG conversion belongs only to this local diagnostic. It must never enter
the accepted RemoteGPU PRESENT path. No GL3.2, Zink, VirGL host or guest/Minecraft
acceptance follows from any Vulkan result.
