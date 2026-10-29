# B1.2d isolated Buffer Texture / Geometry capability probe

Status: implemented for Actions build; **device pending**. Not full B1.2,
VirGL integration, Ubuntu guest GL3.2, Minecraft or performance acceptance.
Branch `experiment/b12d-mobileglues-core-probe`. Accepted
[B1.2c `e989b4d`](evidence/b12c-device-2026-10-29/README.md) and B1.1/a/b
regressions run first. New target `MobileGluesCoreProbe`, bundle
`org.remotegpu.experiments.mobileglues.capabilities`, display **RemoteGPU B1.2d**.
"Core" in a target name is not a conformance verdict. Formal renderer, provider
recipe/bootstrap, backend selection, ADR, transport and server remain unchanged.

## Implemented tests

Three features run in fresh **unshared** frontend contexts, reusing the checked
ANGLE Metal display and pbuffer. One feature's failure is recorded as BLOCKED,
its objects are cleaned, the root is restored, and the next feature is attempted.
EGL recovery/cleanup failure stops the suite instead of continuing with uncertain
bindings. Reports preserve all attempted operations and individual results; no
missing/failed feature is aggregated into PASS. Context isolation is not a test
of cross-context sharing or synchronization.

| Feature | Actual operations / oracle |
| --- | --- |
| R8I signed Buffer Texture | Original GLSL150 `isamplerBuffer` / `texelFetch`, real buffer storage and `glTexBuffer`, four signed values rendered to distinct 8x8 quadrants. |
| RGBA32F float Buffer Texture | Original GLSL150 `samplerBuffer` / `texelFetch`, floating RGBA storage; same independent initial/update/reattach sequence. |
| Geometry | Real `glCreateShader(GL_GEOMETRY_SHADER)`, original GLSL150 triangle input / triangle-strip output / EmitVertex / EndPrimitive, actual translated source, compile/link and two dynamic geometry/color outputs if earlier stages succeed. |

Each Buffer Texture feature has three cases: initial attachment, modified data
via `glBufferSubData` **without any reattachment**, then explicit reattachment as
a separate diagnostic. Every update pixel differs from the original data. A
successful final reattachment never excuses a failed live-update case. Storage
is legally created through generic ARRAY_BUFFER; the extra TEXTURE_BUFFER
buffer-binding target itself, multiple simultaneous TBOs, ranges, all formats,
textureSize and minimum limits are not accepted by these representative tests.
The two geometry cases transform full-screen input triangles into differently
located 6x12 rectangles. A bypassed/no-op GS cannot produce the expected outputs.

All shader sources are exact desktop GLSL150 submitted to the candidate, not
rewritten by the App. Existing checked frontend/raw ANGLE compile/link status,
actual uploaded shader source and logs are reused. Geometry creation errors are
recorded before any subsequent call; compilation/link/draw then remain NOT RUN,
not failed or passed by inference. Errors after translation block that feature.
Creation/source and pixel outputs remain visible in Share Full Report.

All executed outputs compare complete 16x16 RGBA8 images, RGB +/-1 / exact alpha;
at most 3+3+2 new local reads, 2048 checked pixels. Actual images, first mismatches,
totals and GL cleanup are retained. No frame streaming, CPU display, new glFinish,
network or performance measurement is introduced. Leaks are not inferred absent
merely because release calls succeed.

## Why these are real blockers, not version-string tests

OpenGL 3.2 Core defines Geometry Shaders in section 2.12 and Buffer Textures in
3.8.5. Buffer data changes must affect already attached textures. Missing either
required semantic blocks a claim of full GL3.2 Core; these are not optional-only
diagnostics. See [Khronos GL3.2 Core specification](https://registry.khronos.org/OpenGL/specs/gl/glspec32.core.pdf),
[TexBuffer API](https://raw.githubusercontent.com/KhronosGroup/OpenGL-Refpages/main/gl4/glTexBuffer.xml)
and [shader creation API](https://raw.githubusercontent.com/KhronosGroup/OpenGL-Refpages/main/gl4/glCreateShader.xml).
This does not establish which paths Vanilla or a particular Modpack executes:
that requires later real workload/guest evidence. Mod-specific extra features,
optional diagnostics and sustained-performance gates remain separately untested.

Source evidence at immutable MobileGlues `97558a69157b033b890958b1e49258c5b51a80c6`:

- `gles/loader.cpp:set_hardware` selects texture-buffer emulation for ES <=3.1.
- `gl/glsl/glsl_for_es.cpp:process_sampler_buffer` only rewrites isamplerBuffer,
  not plain float samplerBuffer. `gl/buffer.cpp:glTexBuffer` uploads emulated 2D
  storage; `glBufferSubData` only updates the underlying buffer. Source inspection
  raises a stale-texture/unsupported-type risk, not a device result.
- `gl/shader.cpp:glCreateShader` passes the shader type to backend GLES. The
  accepted GLES3.0 metadata suggests Geometry may be rejected; runtime creation
  errors and actual operations determine the result, not the suggestion.
- No compatibility-layer fix, fake version/extension, API substitution or
  alternative backend is installed to make these diagnostics pass.

## CI and device procedure

All compilation in Actions. ASan/UBSan tests the actual CPU signed/float buffer
and geometry oracles against literal golden grids, catches stale updates and
rejects aggregate PASS when any verdict is blocked/not-run. Source guards check
the no-reattach path, real GS creation/attachment/draw, fresh contexts, cleanup,
independent bundle and accepted-source provenance. CPU tests are NOT GPU evidence.

Keep accepted Apps installed. Self-sign **RemoteGPU B1.2d**, fresh process,
**Run Buffer / Geometry Probe**, then **Share Full Report**, even if BLOCKED.
No Ubuntu server change. Preserve crash logs if a crash prevents a report.
Expect B1.1/a/b/c regressions, three B12D_STAGE/FEATURE/SUMMARY records, precise
creation/compile/output errors or pixel checks and context cleanup. If a new
feature is blocked, prior accepted regressions are not revoked. A final BLOCKED
is meaningful compatibility evidence, not an invitation to override capabilities.

Next: actual device results, then targeted source fixes/blocker report. Full
B1.2, limits, cross-context ordering, B1.3 guest integration and Minecraft remain
unaccepted even if all representative B1.2d cases happen to pass.
