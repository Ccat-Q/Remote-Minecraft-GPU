# B1.2d blockers and bounded retest preparation

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

## Minimal repair source prepared locally, NOT built or enabled

tools/ci/prepare_mobileglues_b12d_retest.py is an explicit second adaptation
after the unchanged base recipe. It checks three pinned file hashes, records
its own recipe/upstream/adapted hashes into the source manifest, and:

1. Replaces diagnostic glGetError with DiagnosticErrors.hpp: return a pending
   frontend error without consuming an unrelated backend error; next query uses
   the actual backend. No fabricated zero.
2. Moves glDrawArrays out of the native passthrough into drawing.cpp, calling
   existing prepareForDraw before the actual GLES draw. No duplicate export,
   App sampler-uniform injection or alternate backend.

CI policy tests and mutation/hash guards are prepared, but **have not run**.
All compilation remains Actions-only. The repair is deliberately not invoked by
the baseline iOS workflow. Accepted artifacts, base provider recipe, dispatch
and formal renderer are unchanged. No full TBO/Geometry/live-update repair,
new device acceptance or performance result is claimed.

The broader alternative is typed/multiple TBO mapping, all storage update APIs,
dependency invalidation, shared-context lifetime and Geometry execution together.
That has much larger semantic/maintenance risk. The bounded repair is recommended
first to obtain real errors and distinguish initial R8I failure from update
failure; it must not waive any failing case or tolerance.

## Publication blocker and remaining actions

Git commit/push/branch creation was **not executed**: automatic permission review
returned model-capacity errors and a timeout on the allowed retries. This is a
review-service failure, not a determination that the work is unsafe. No bypass,
local compilation, Actions run or new IPA occurred. Changes remain uncommitted
on experiment/b12d-mobileglues-core-probe; the intended retest branch does not
yet exist.

When review is available:

- Commit real failure evidence separately, then create the isolated retest
  branch and commit repair work there. Preserve the accepted renderer.
- Add a separate target/bundle and opt-in workflow, strict/baseline cache
  separation and complete LGPL corresponding source.
- Add an intentional invalid-enum negative control to verify strict error return
  and drain on device, actual sampler/width uniform observations after draws,
  and a separate raw-backend Geometry creation control. Do not substitute raw
  objects for failed frontend objects.
- Retain all signed/float initial/update/reattach and Geometry oracles, prior
  regressions and independent contexts. Run CI/build in Actions, publish/check
  a new IPA, then stop for actual device retest. Reattach cannot excuse updates.

Maintenance estimates are qualitative: this diagnostic repair is bounded;
full TBO coherence is medium/high scope; GS on a backend unable to create the
stage is high scope requiring separate implementation/maintenance evidence.
Existing VirGL/vtest/QUIC/lifetime machinery remains a reusable baseline, but
MobileGlues integration has not met its entry gate. MobileGL/MoltenVK are options
for an approved future investigation, not automatic migrations or concurrent
full backends. No credible schedule/performance number is inferred here.
