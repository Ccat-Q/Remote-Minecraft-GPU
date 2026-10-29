# B1.2b device acceptance: representative instancing / same-context Sync only

Summary of the actual user-submitted report, not reconstructed raw output or
CI simulation. iPhone18,3 / iOS27.0.1 (24A446), code
`f91d6838b1534a65a8c7e6eecc4830a2e47c572d`, Actions `40819548554`.
[Full build provenance](provenance.json) matches that report, including unsigned
candidate hash `6ecf6f14f3a79cfedfe288cce5d61d8d5c1bf563ca160aa4216fb008b0486dce`.

- B1.1 regression passed: checked providers/bootstrap, actual context/shared
  content, exclusive migration/return, and later cleanup calls.
- B1.2a regression passed: real GLSL150 translation/compile/link, three actual
  dynamic images, 768 checked pixels with zero mismatches.
- B1.2b original GLSL150 shaders used gl_InstanceID, flat ivec2 varying and
  texelFetch. Captured ANGLE source was ESSL300. Both shader stages and program
  link had frontend/raw backend status 1 and empty logs; observed GL errors 0.
- B12B_CASE 0: 4 instances, 256 checked pixels, 0 mismatches; actual four 6x6
  regions were red/green/blue/white with the expected gaps and background.
- B12B_CASE 1: 2 instances, 256 checked pixels, 0 mismatches; actual lower colors
  included 1030e0ff and 701840ff, upper regions remained background.
- B12B_CASE 2: 0 instances, 256 checked pixels, 0 mismatches, all background.
- Each real Fence first returned 0x911b (TIMEOUT_EXPIRED), then 0x911a
  (ALREADY_SIGNALED), with two observations and GL0. Each status query returned
  0x9119 (SIGNALED); delete-before-read checks reported live=NO.
- Local observed durations: case0 1.285ms, case1 1.255ms, case2 1.271ms. These
  include polling/thread wait; NOT GPU timestamps, FPS, network or end-to-end
  latency. This evidence covers an actual pending-to-complete path, not a
  manufactured retirement delay, but not sustained/slow-GPU stress or cancellation.
- B1.2b object release calls GL0; texture deletion/unbind/context and pbuffer
  destruction/terminate/thread-release GL0/EGL0x3000. Final limited-scope PASS.

Accepted ONLY: these representative glDrawArraysInstanced/gl_InstanceID/flat
varying/texelFetch results and same-context Fence-before-pixel-read completion
and identity retirement. Not indexed instancing or attribute divisors, all Sync
semantics, cross-context GPU dependencies, in-flight cancellation, performance
or leak profiling. Depth/Stencil/Blending/TextureBuffer/Geometry, full B1.2,
VirGL/Ubuntu guest GL3.2 and Minecraft/NeoForge remain unaccepted. Local tiny
oracle reads do not change the GPU-only production display path.
