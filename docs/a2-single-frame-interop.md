# A2.0: one-shot VirGL resource interop diagnostic

Implementation based on accepted A1 `f7413ff245b06c27aa1fbb9b3dcbd527ba32be42`,
isolated on `feature/a2-single-frame-interop`. **iPhone acceptance pending.**
This does not implement continuous remote PRESENT, QUIC display scheduling,
Minecraft, or the still-blocked guest GL 3.2 / GLSL 150 capability gate.

## Locked API contract

UTM virglrenderer `482f9d8b8c2d2288efa10a027116216909d2c226`:

- [`src/virglrenderer.c`, `virgl_renderer_resource_get_info_common/get_info`](https://github.com/utmapp/virglrenderer/blob/482f9d8b8c2d2288efa10a027116216909d2c226/src/virglrenderer.c):
  invalid handles return EINVAL; a non-pipe/blob resource can return success
  without a GL texture. Zero-initialize info and reject zero tex_id. External
  callback-owned EGL initialization does not export a DMA-BUF or Metal handle.
- [`src/vrend/vrend_renderer.c`, `vrend_renderer_resource_get_info`](https://github.com/utmapp/virglrenderer/blob/482f9d8b8c2d2288efa10a027116216909d2c226/src/vrend/vrend_renderer.c):
  tex_id is resource-owned gl_id, not an ownership transfer. Info contains base
  dimensions, format, stride and Y_0_TOP, **not target, samples, mip or layer**.
  The test owns the creation descriptor: PIPE_TEXTURE_2D=2, RGBA8_UNORM=67,
  width 640, height 360, depth/array=1, level/layer=0, nr_samples=0 (one sample).
  Other formats/flags/targets are rejected, not silently converted or advertised.
- Same source, `vrend_create_context`/subcontext callbacks: resource GL objects
  are in the root share group. New adapter borrows **ANGLEHost's EGLDisplay**
  and creates its copy context sharing host.root. FBO names remain private to
  the copy context. Neither context may delete the borrowed source texture.
- [`src/virgl_protocol.h`](https://github.com/utmapp/virglrenderer/blob/482f9d8b8c2d2288efa10a027116216909d2c226/src/virgl_protocol.h)
  and `vrend_decode.c`: existing CREATE_OBJECT(SURFACE), SET_FRAMEBUFFER_STATE,
  CLEAR and RESOURCE_COPY_REGION produce the diagnostic pattern. No new opcode,
  local GLES pattern draw, image upload, or protocol extension is required.

## Implemented one-shot path (not yet device-accepted)

`RGPUVirglPattern.hpp` generates real legacy vtest CREATE_RENDERER/resources
and one SUBMIT_CMD. Five GPU clears and four GPU resource copies generate a
dark background and asymmetric red/green/blue/yellow rectangles.

`RGPURemotePresent.mm` runs exclusively on the existing serial renderer queue:

1. Initialize the extracted, unchanged ANGLEHost callbacks, readbacks disabled.
2. Submit pattern, retainForPresent, UNREF both guest resources **before**
   producer completion; the source pin keeps the target alive.
3. Independently poll the fixed producer fence (10-second timeout, no packet
   needed), get resource info, create a shared GLES 3.0 copy context.
4. Check glIsTexture, source read-FBO completeness, normalized linear RGBA8
   attachment bits and destination completeness/samples/dimensions. Only then
   use GLES 3.0 core glBlitFramebuffer, no vertical inversion or manual swizzle.
   Incompatible attachments fail with diagnostics; shader-copy support is
   not implemented speculatively.
5. Flush and wait for a local GLsync (10-second timeout), detach source, restore
   producer context. Release the pin, assert source removal and reuse the
   handle. GPU-clear the new source MAGENTA, wait for that completion and free
   it **before** displaying the independent IOSurface snapshot. Magenta on
   screen is a failure: it indicates missing snapshot isolation.
6. Metal samples the IOSurface-backed BGRA8 texture via the existing orientation
   shader. Keep CVPixelBuffer/IOSurface/MTLTexture through Metal completion;
   then destroy copy context/surface before the host EGLDisplay.

Conservative waits, including failure-path glFinish and Metal waitUntilCompleted,
are explicitly diagnostic-only. No concurrent vtest ingress exists in this mode,
so no later command can overwrite the source before snapshot completion. This
does not validate the future continuous-session admission/backpressure policy.

## Evidence boundaries

- `tests/a2_virgl_pattern.cpp` validates every pixel against an independent
  Linux receiver-local oracle, rejects a corruption, and tests pinned UNREF /
  final release / handle reuse. Its single CPU readback is **CI-only**, outside
  the iOS adapter and vtest transport. Linux software rendering is not iPhone
  GPU, EGL sharing, IOSurface, Metal, or image-orientation acceptance.
- iOS display code does not call glReadPixels, map/lock/copy CVPixelBuffer data,
  or feed TRANSFER_GET. The existing native session rejects TRANSFER_GET.
- Actions embeds `RGPUProvenance.json`: actual app SHA, accepted A1 SHA,
  explicitly selected sysroot run/source, UTM SHA parsed from its job log,
  dependency pins fetched at that UTM commit, compatibility-recipe hash and
  framework binary hashes. No latest-main dependency selection.
- Device report preserves partial stages/errors and reports only technical
  completion plus **VISUAL ACCEPTANCE PENDING**. Shared texture visibility,
  correct GPU copy/image and cleanup still require the physical device.

Follow [DEVICE-TEST](../ios/DEVICE-TEST.md#a20-single-frame-virgl-resource-interop)
for installation and image checks. Existing A1/Core/explicit glReadPixels and
lifetime regression gates are retained; no approved ADR or renderer is changed.
