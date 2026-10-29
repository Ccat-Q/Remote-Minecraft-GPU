# B1.2a real device acceptance: representative GLSL150 / dynamic output only

Summary of the user-supplied full report, not reconstructed raw output or CI
simulation. iPhone18,3 / iOS27.0.1 (24A446), source
`c6c443facf52929f6caaa760f8bad675e4f4bde5`, Actions `40818346056`.
[Full build provenance](provenance.json) matches the user report. Candidate hash
is `6b3f2c2f280a715b8c40257e687e5d32f9ce9c920a5fff38ba9f57c5e711a07b`.

Actual device results:

- B1.1 provider/bootstrap/context/shared-content/worker-migration regression ran
  successfully in this rebuilt candidate. All added function owners were checked.
- Original vertex and fragment shaders were `#version 150`; captured ANGLE-uploaded
  sources were `#version 300 es`, with actual inputs/varying/uniform operations,
  not just an App-side version replacement. Sources are retained below.
- Both stages: frontend and raw backend compile status 1, empty compile logs;
  program: frontend and raw backend link status 1, empty link logs. GL errors 0.
- Active uniforms: uOffset=1, uScale=0, uTint=2, uTex=3. FBO RGBA8 16x16,
  status 0x8cd5. Actual VAO/VBO/FBO and textured triangle drawing executed.
- Case0: sampler0, rect(1,2,6,12), 256 pixels checked, 0 mismatches.
- Case1: sampler1, rect(9,2,6,12), 256 pixels checked, 0 mismatches; actual tint
  output included 800000ff, 00bf00ff, 0000ffff, 80bfffff.
- Case2: sampler0, rect(1,0,6,12), 256 pixels checked, 0 mismatches; actual colors
  2040e0ff, e02040ff, 40e020ff, c08040ff. Total 768 pixels, 0 mismatches, fixed
  RGB +/-1 / exact-alpha tolerance; background/position/row order checked too.
- Shader/program/VAO/VBO/FBO/texture release calls: GL0. Context texture delete,
  unbind, shared/root/pbuffer destroy, terminate and thread release: GL0/EGL0x3000.
- Device emitted the B1.2a limited-scope PASS plus B1.1 regression/cleanup PASS.

Accepted ONLY: these GLSL150 vertex/fragment operations, translation and actual
compile/link, representative VAO/VBO/FBO, sampled texture, uniforms/varying and
three distinct outputs on this device/build. No performance/driver-leak verdict.
Instancing, Depth/Stencil, Blending, Texture Buffer, Sync/Fence and Geometry
Shader are NOT TESTED by this report. Full B1.2, VirGL, Ubuntu guest GL3.2 and
Minecraft/NeoForge remain unaccepted. Frontend version/profile metadata is not
substituted for functional evidence. Local oracle reads are not frame streaming.
