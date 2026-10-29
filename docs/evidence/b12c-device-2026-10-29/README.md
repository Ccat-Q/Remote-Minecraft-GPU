# B1.2c device acceptance: representative depth, stencil and blending only

Summary of the actual user-submitted report, not reconstructed raw pixels or
CI simulation. iPhone18,3 / iOS27.0.1 (24A446), code
`e989b4d86d70d1fa15fbbde119bcdac9287ac6ba`, Actions `40821114364`.
[Full provenance](provenance.json) from the delivered artifact matches that report,
including candidate hash `ff8171a77c1dd8e41fce5ef6e1f0a7ec5c238eac91167d498c827be365949066`.
Historical DEVICE_PENDING text in build metadata is retained, not rewritten.

- Checked frontend/backend providers and Metal platform resolver passed; bootstrap
  result 0 / 384 backend entries. No system GLES provider selected.
- B1.1 actual context/sharing/exclusive migration/return checks passed.
- B1.2a and B1.2b each checked 768 actual pixels with zero mismatches. Same-context
  Fences actually returned TIMEOUT_EXPIRED then ALREADY_SIGNALED, status SIGNALED,
  and retired before pixel reads. Observations 1.288 / 1.260 / 1.273ms are local
  polling/thread-wait durations, not GPU timestamps, FPS or network latency.
- B1.2c original GLSL150 VF shaders translated to captured ESSL300 source;
  frontend/raw backend compile and link statuses all 1, logs empty, GL errors 0.
- Packed DEPTH24_STENCIL8 reported actual depth bits 24 / stencil bits 8;
  color RGBA8 16x16 FBO complete (0x8cd5).
- Depth LESS/occlusion: 256 pixels, zero mismatches. Far blue did not overwrite
  red; the center was green. Depth write-mask case: 256 pixels, zero mismatches;
  later yellow replaced the non-depth-writing green center.
- Stencil compare/REPLACE/write-mask/protected-INCR sequence: 256 pixels, zero
  mismatches; red rectangle and green complement matched the complete oracle.
- Separate RGB/Alpha blending: 256 pixels, zero mismatches; actual overlap
  `604060ff`, red-only `800080ff`, green-only `0040bfff`, background `0000ffff`.
- Total new B1.2c checks: 1024 actual pixels / 0 mismatches, fixed RGB tolerance
  1 and exact alpha. Actual images were included in the user's full report.
- Renderbuffer release/state reset and remaining GL object cleanup returned GL0;
  texture cleanup/unbind/context/pbuffer destruction/terminate/thread-release
  succeeded with EGL0x3000. Final limited-scope PASS.

Accepted ONLY these representative depth LESS/occlusion/write-mask, stencil
compare/REPLACE/write-mask and separate blending results plus retained regressions.
Not all depth/stencil functions, front/back stencil, blend equations, formats,
multisampling, cross-context GPU synchronization, cancellation, sustained
performance or leak profiling. Texture Buffer / Geometry, full B1.2, VirGL/Ubuntu
guest GL3.2 and Minecraft remain unaccepted. Local oracle reads do not alter the
GPU-only production display path. Translated source below is actual reported
source with whitespace normalized, not a substitute App-side translation.
