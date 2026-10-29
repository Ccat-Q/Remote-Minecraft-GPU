# B1.2d blockers and bounded repair retest

Actual device status: all three B1.2d features **BLOCKED** at `528ab1e`.
[Report summary, delivered provenance and shader failures](evidence/b12d-device-2026-10-29/README.md).
No B1.3 integration, caps/version changes, backend migration or formal renderer
change follows from these failures or is implemented here.

## Concrete blockers

| Capability | Device evidence | Source evidence / modification scope |
| --- | --- | --- |
| R8I TBO | Constant RGBA128,64,191,255; initial 192 mismatches, update and reattach 256 each; real compile/link succeeded. | gl_native.cpp forwards glDrawArrays without prepareForDraw, unlike indexed/instanced calls in drawing.cpp. Missing TBO sampler/width setup is a source defect consistent with this output, not yet proven the only cause. |
| RGBA32F TBO | Actual fragment compile status 0; GL_EXT_texture_buffer unsupported; no draw executed. | gl/glsl/glsl_for_es.cpp only processes isamplerBuffer. Float support needs typed translation/resource binding; live changes need maintained buffer dependencies, not App reattach workarounds. |
| Geometry | Actual create returned 0, observed errors zero; compile/link/draw not run. | gl/shader.cpp forwards creation to GLES. Exact error cause requires strict errors and a separate raw-backend control. A complete GS implementation is not a source-string substitution. |

Source pin MobileGlues `97558a69157b033b890958b1e49258c5b51a80c6` was checked
against the local pristine checkout. Required function behavior is documented in
[GL3.2 Core sections 2.12 and 3.8.5](https://registry.khronos.org/OpenGL/specs/gl/glspec32.core.pdf).
Actual Vanilla/Modpack paths still require workload evidence. Advertised
4.0/GLSL4.00 strings cannot establish full GL3.2 Core semantics.

## Error-observability defect

Pinned gl/getter.cpp:glGetError consumes frontend/backend errors and returns
GL_NO_ERROR unconditionally. Apple ignore_error=None disabled separate
compile/link-status cheating, but did not repair this path. Raw backend queries
after the frontend getter may also see an already consumed error. No unobserved
error code is invented for the Geometry report.

Historical actual pixel matches, captured source, raw compile/link statuses, FBO
status and returned EGL results remain evidence. Historical frontend GL0 and
cleanup GL0 do not independently prove absence of errors or leaks. Preserve
reports/manifests, qualify stronger claims, and rerun prior regressions strictly.

## Minimal repair for existing B1.2d, built / device retest pending

tools/ci/prepare_mobileglues_b12d_retest.py is an explicit second adaptation
after the unchanged base recipe. It checks three pinned file hashes, records
its own recipe/upstream/adapted hashes into the source manifest, and:

1. Replaces diagnostic glGetError with DiagnosticErrors.hpp: return a pending
   frontend error without consuming an unrelated backend error; next query uses
   the actual backend. No fabricated zero.
2. Moves glDrawArrays out of the native passthrough into drawing.cpp, calling
   existing prepareForDraw before the actual GLES draw. No duplicate export,
   App sampler-uniform injection or alternate backend.

CI policy/sanitizer tests and all six repair mutation/scope guards passed in
Actions, alongside the existing 17 provider/source guards and 32 Swift tests.
All compilation remained Actions-only. The repair is invoked only by the
independent b12d1 retest branch/target, never baseline scopes. This is a repair
retest of the existing B1.2d, not another capability milestone.
Accepted artifacts, base provider recipe, dispatch
and formal renderer are unchanged. No full TBO/Geometry/live-update repair,
new device acceptance or performance result is claimed.

The broader alternative is typed/multiple TBO mapping, all storage update APIs,
dependency invalidation, shared-context lifetime and Geometry execution together.
That has much larger semantic/maintenance risk. The bounded repair is recommended
first to obtain real errors and distinguish initial R8I failure from update
failure; it must not waive any failing case or tolerance.

## Publication and remaining actions

Earlier automatic review capacity/timeouts delayed publication; no bypass or
local build occurred. Review subsequently recovered: actual failure evidence
was committed separately as `85b10b0` on the existing B1.2d branch, then
`experiment/b12d1-mobileglues-retest` was created. Repair code
`18400ad4e41995e995e3807ac2c96da745ad0a89` is committed/pushed. Both
[CI 40901304416](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40901304416)
and [iOS build 40901304444](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40901304444)
passed. **No replacement device report exists yet.**

### Verified repair-candidate delivery

- [Self-signable IPA artifact 12908524604](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40901304444/artifacts/12908524604):
  `MobileGluesRetestProbe-unsigned.ipa`, SHA256
  `9acd7c35d9ba78bc2b077d6b0ee0bd16c47c95a8f783ab329c02e5e4f46bfa89`.
  Downloaded SHA256SUMS and ZIP integrity passed. Embedded provenance has the
  exact source/run, accepted B1.1/a/b/c chain and `b12d_failure_sha=528ab1e...`,
  never an accepted B1.2d entry.
- Only MobileGluesProbe/EGL/GLESv2 frameworks are embedded. Actual candidate
  hash `df6ba87d320adbe1c89dc803f8c684068c9866470825bc55b089f2b01cdbcfd5`
  differs from the failed candidate; actual EGL/GLESv2 hashes match the unchanged
  accepted ANGLE sysroot. Hash scope is unsigned before external signing.
- [Diagnostics and complete LGPL corresponding source 12908828615](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40901304444/artifacts/12908828615)
  include the modified candidate/dependencies, both recipes, source hashes,
  compiler output, exports and packaging/linkage checks. The opt-in repair recipe
  SHA256 is `2d93233b0095b7d97907943253578772bdd433baea9521d73d97ca89d715ee68`.
  Downloaded source archive integrity and all four adapted file hashes were
  checked against the embedded recipe. Both repaired GL exports are present;
  the App has no hard links to graphics providers.
  The candidate compile retains upstream warnings; build success is not a claim
  of warning-free source, correct device semantics or absence of leaks.

Repair retest sequence:

- Separate target/bundle and opt-in workflow, strict/baseline cache
  separation and complete LGPL corresponding source are built and published.
- An intentional invalid-enum negative control verifies strict error return
  and drain on device, actual sampler/width uniform observations after draws,
  and a separate raw-backend Geometry creation control. Never substitute raw
  objects for failed frontend objects.
- All signed/float initial/update/reattach and Geometry oracles, prior
  regressions and independent contexts are retained. Next is actual device
  retest; reattach cannot excuse updates.

Install the delivered **RemoteGPU B1.2d.1** repair candidate, tap **Run Strict
Retest**, then **Share Full Report** including failures. Bundle
`org.remotegpu.experiments.mobileglues.capabilities.retest` keeps existing Apps.
The negative control runs before regressions; failure stops the suite. Float
TBO/live coherence/Geometry are not implemented by this minimal repair; a
successful build must not be reported as a successful device capability gate.

Maintenance estimates are qualitative: this diagnostic repair is bounded;
full TBO coherence is medium/high scope; GS on a backend unable to create the
stage is high scope requiring separate implementation/maintenance evidence.
Existing VirGL/vtest/QUIC/lifetime machinery remains a reusable baseline, but
MobileGlues integration has not met its entry gate. MobileGL/MoltenVK are options
for an approved future investigation, not automatic migrations or concurrent
full backends. No credible schedule/performance number is inferred here.
