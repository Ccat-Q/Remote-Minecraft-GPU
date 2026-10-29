# Existing B1.2d TBO repair revision — device pending

Same `experiment/b12d1-mobileglues-retest` branch, MobileGluesRetestProbe target
and `.mobileglues.capabilities.retest` bundle. This repairs existing B1.2d gates,
not a new milestone. [Previous actual strict retest](evidence/b12d1-device-2026-10-29/README.md)
proved initial R8I/draw preparation fixed and SubData propagation still stale.
All three required capability verdicts remain BLOCKED until actual new results.

## Reproducible repair-candidate delivery

- Code `b234149c917661e499c156b3107c7cd90370181e`.
  [CI 40907010085](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40907010085)
  and [iOS build 40907010084](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40907010084)
  passed. Existing 17 source/provider guards, six strict guards, three new TBO
  guards, actual helper/upload-state sanitizer tests and generated GLSL syntax
  validation passed; none is GPU capability acceptance.
- [Self-signable IPA artifact 12912825757](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40907010084/artifacts/12912825757):
  `MobileGluesRetestProbe-unsigned.ipa`, SHA256
  `7da59e9b273e77fec99dba311ec2a0a9852cdc272f2207a8e953d46dbb57183c`.
  Downloaded checksum and ZIP integrity passed; only MobileGluesProbe/EGL/GLESv2
  frameworks are embedded. Candidate hash
  `4fe62e6542354ff4106a359b705d891312f5e4bc469b82f409747b4910ff7ff4`;
  actual EGL/GLESv2 hashes remain identical to accepted ANGLE run `40636888480`.
  Hashes describe unsigned bytes before external signing.
- [Diagnostics and complete LGPL corresponding source 12912825770](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40907010084/artifacts/12912825770)
  include all modified candidate/dependency sources, three adaptation recipes,
  compiler/linkage/export diagnostics and complete provenance. Local source
  archive integrity and all six TBO adapted-file hashes match the recipe;
  embedded and archived provenance are byte-identical. Repair recipe SHA256
  `b29a360d9dc93b370dd4e4be03a5ed212f5097e393f6ce929cf72aee632e62c5`.
  Upstream candidate warnings remain; this is not a warning-free-source claim.
- **Device retest pending.** The previous `18400ad` actual report is preserved;
  no accepted B1.2d field is introduced. Geometry still runs as a real gate and
  may keep the aggregate BLOCKED even if both TBO features pass.

## Judgment and implementation scope

Per-draw full reupload would hide the missing dependency model and add permanent
work to unchanged draws. Chosen alternative: maintain texture-to-buffer edges in
the existing share-group buffer state and eagerly copy only affected whole texels
after BufferSubData. BufferData reallocations resize/reupload attached textures.
No App reattachment, CPU readback, new glFinish or fake extension is introduced.
These are GPU buffer-to-texture transfers on the same current context.

Deleting textures removes edges; deleting buffers removes update edges while
already-copied texture storage remains, preventing recycled names from silently
updating old textures. Reattachment replaces the edge; buffer=0 detaches it.
Upload saves/restores actual active texture, unit-15 binding, unpack buffer,
alignment, row length and skip state. Partial-byte writes round out to whole
texels read from actual buffer storage; row crossings/short tails are handled.
Cross-context ordering/lifetime behavior and driver leaks remain unaccepted.

Token-aware typed lowering handles scalar named samplerBuffer/isamplerBuffer/
usamplerBuffer declarations and their texelFetch calls before glslang/SPIRV-Cross.
Unrelated sampler2D calls/comments and nested index expressions remain untouched.
Backend shader source and compile/link statuses still decide device success.
Arrays, sampler parameters, macros/aliases and internal-name conflicts are not
silently guessed; unsupported translation can fail the feature. The existing
single emulation binding/dimension-set limitation remains; multiple simultaneous
TBO samplers or mixing TBO with ordinary sampled textures is NOT accepted.

Only BufferData/SubData mutation paths are repaired here. Map/unmap/flush,
persistent maps, buffer copies, shader/transform-feedback writes, buffer ranges,
all formats/limits and broad resource lifetime conformance are NOT repaired or
accepted. R8I and RGBA32F are the unchanged actual device cases. Geometry remains
an actual failing gate on the same ANGLE backend; no bypass or backend substitution.

## Verification and delivery boundary

All compilation is Actions-only. Native ASan/UBSan runs the actual attachment,
range, typed-lowering and upload-state code with a recording backend. glslang
validates generated desktop shader syntax. These are NOT GPU execution. Mutation
guards reject changed pins/anchors and enforce recipe/source coverage; complete
modified LGPL source is archived, including added headers and upload code.

The third opt-in recipe runs only after unchanged base and strict-error recipes.
Its source/recipe hashes enter provenance and framework cache identity. Provenance
retains both `b12d_failure_sha` and `b12d1_failure_sha`, never accepted B1.2d.
Formal renderer, base recipe/bootstrap, ANGLE, ADR and server are unchanged.

Device procedure: install the delivered repair revision over **RemoteGPU B1.2d.1**,
tap **Run Strict Retest**, then **Share Full Report** including BLOCKED. Check
the report header says **TBO REPAIR REVISION**, not the earlier strict-only build.
All B1.1/a/b/c regressions, negative error control, independent contexts and original
initial/update-without-reattach/explicit-reattach/Geometry pixel gates remain.
Do not weaken tolerances or waive failed live updates. No full B1.2, VirGL/guest,
Minecraft, streaming, performance or driver-leak verdict.
