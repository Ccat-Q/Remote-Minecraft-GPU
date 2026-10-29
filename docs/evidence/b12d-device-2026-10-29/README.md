# B1.2d actual device BLOCKED: three independent capability failures

Actual user-submitted report summary, not reconstructed raw output or a CI
simulation. iPhone18,3 / iOS27.0.1 (24A446), source
`528ab1ea3485241ea5c0399e9b35245a80e273c3`, Actions `40896067592`.
[Full delivered provenance](provenance.json) matches the report; candidate unsigned
SHA256 `d8322151626f0c7e5774a5459e4ee46be3f913040feaaaeea746e22cd980cc8d`.
Historical DEVICE_PENDING manifest text is retained without rewriting it.

Provider/bootstrap checks succeeded (384 backend entries); B1.1 context sharing
and migration and B1.2a/b/c real output regressions succeeded: 768 + 768 + 1024
pixels, zero mismatches. Fences observed pending then signaled and were retired.
Polling durations 1.308 / 1.258 / 1.272ms are NOT GPU/performance data.

| New feature | Actual result |
| --- | --- |
| TBO R8I | VF translation/compile/link statuses 1; RGBA8 FBO complete. All three outputs were constant RGBA(128,64,191,255). Initial case 192/256 mismatches; update without reattach 256/256; explicit reattach 256/256. BLOCKED, not a live-update-only failure. |
| TBO RGBA32F | Actual translated source required GL_EXT_texture_buffer. Both frontend/raw ANGLE fragment compile statuses 0. Log: extension unsupported, samplerBuffer reserved/syntax error. Link/attachment/draw NOT RUN. BLOCKED. |
| Geometry | Actual frontend glCreateShader(GL_GEOMETRY_SHADER) returned 0; frontend and subsequent raw backend error queries reported 0. Compilation/link/draw NOT RUN. BLOCKED. No unobserved error code is inferred. |

Each feature had a fresh unshared context. All reported object release and EGL
unbind/root restore/destroy calls returned; final root/shared context cleanup
also returned. Driver leak profiling was not performed. Final three summaries
and overall gate were BLOCKED. Prior output successes are not full GL3.2 or
VirGL/guest/Minecraft acceptance. Actual images remain in the user's full report;
captured sources below use normalized whitespace, not an App rewrite.

## Newly discovered error-observability caveat

Pinned upstream `gl/getter.cpp:glGetError` consumes frontend/backend errors but
**always returns GL_NO_ERROR**, independently of ignore_error. Disabling Partial
compile/link cheating in the original Apple recipe did not fix this separate
path. Consequently reported frontend GL0 is NOT evidence that no error occurred;
querying raw backend after it may also see an already consumed error. This
qualifies all earlier B1 frontend GL0 observations and cleanup error checks too.
It does not fabricate or invalidate actual matching pixels, explicit raw shader
compile/link statuses, FBO status or returned EGL results. Strict error behavior
requires a new isolated retest; earlier binary provenance/results remain intact.

Source also shows `glDrawArrays` in gl_native.cpp forwards directly without
`prepareForDraw`, unlike glDrawElements/Instanced. That omits emulated TBO sampler
and dimension setup. This is a concrete source defect consistent with the R8I
constant output, not yet a device-proven fix or proof it is the only R8I defect.
