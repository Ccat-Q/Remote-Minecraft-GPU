# B1.2d isolated Buffer Texture / Geometry capability probe

Status: Actions iOS build and CI passed; **device pending**. Not full B1.2,
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

## Reproducible delivery

- Code `528ab1ea3485241ea5c0399e9b35245a80e273c3`, branch
  `experiment/b12d-mobileglues-core-probe`. Actual B1.2c evidence is preserved
  separately in `ce0b9f9` on its accepted branch; no earlier records removed.
- [iOS Actions 40896067592](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40896067592)
  **passed**: ARM64 candidate compilation, export/linkage checks, standalone Core
  target compile/package, exact `.capabilities` bundle/scope/accepted-source
  ancestors and packaged framework hashes/isolation. No App compiler errors
  or warnings found in the retained build log. No runtime result follows.
- [Self-signable IPA artifact 12905989730](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40896067592/artifacts/12905989730):
  `MobileGluesCoreProbe-unsigned.ipa`, SHA256
  `b1bf1a294971373645f261e23b984b2c895cec48b5745ef69970a595e246a0e8`.
  Downloaded checksum/ZIP integrity and embedded source/run/scope/accepted B1.1/a/b/c
  provenance verified. No new Linux workload artifact is needed for this standalone
  network-free device batch.
- [Build diagnostics and complete LGPL corresponding source 12907561067](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40896067592/artifacts/12907561067):
  actual compiler/linker output, exports, source recipe/pins, full provenance,
  Xcode16.4/SDK18.5 toolchain and complete modified candidate/dependency source.
  Downloaded archive integrity checked, not patch-only distribution.
- [CI 40896067702](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40896067702)
  **passed**: signed/float TBO update and Geometry CPU oracles / aggregation policy
  under ASan/UBSan; retained B1.1/a/b/c, native vtest and double-slot tests;
  17 MobileGlues source/isolation/provenance checks; 32 Swift tests; Linux
  proxy/protocol and Mesa patch gates. All compilation Actions-only. NOT device
  execution or shader capability proof.
- Rebuilt unsigned candidate SHA256
  `d8322151626f0c7e5774a5459e4ee46be3f913040feaaaeea746e22cd980cc8d`.
  Exact MobileGlues recipe, adapted/upstream source hashes and dependency pins
  match accepted B1.2c; no bit-identical binary claim. Packaged ANGLE EGL/GLESv2
  hashes exactly match the accepted artifact reused without rebuild.
- Actual changes: standalone target/UI/provenance and fresh-context test runner,
  signed/float TBO and Geometry fixtures/draws/oracles, reused actual compile/link
  logging, CI and approved concise docs/device steps. Formal `ios/Renderer`,
  `ios/App`, `ios/RemoteGPU`, Provider bootstrap/recipe and ADR unchanged.

New runtime errors/performance: **not measured yet**. The source risks above are
not substituted for actual device errors. Next action is to install B1.2d and
share its complete per-feature report, including BLOCKED and any crash logs.
