# A3.2 double IOSurface slots (implemented, device acceptance pending)

Based on accepted A3.1 app `a87970e`; separate branch
`feature/a32-double-surface`. A2.1 sync remains default, A3.1 single-slot stays
selectable, and A3.2 is opt-in under **测试设置 → 使用 A3.2 双槽异步测试**.
No renderer/provider, Mesa/wire protocol, DNS, production deployment or ADR change.

## Correctness boundary

Two persistent, lazily allocated shared EGL copy contexts / IOSurfaces /
MTLTextures alternate. The native `RGPUDisplaySlots.hpp` engine is the actual
ownership authority, tested with sanitizers. Tickets include slot, generation,
frame, resource and afterSequence. The Swift order model independently verifies
stream sequence, native admission identity, snapshot and display notifications.

```text
FREE -> PRODUCER -> COPYING -> READY -> PRESENTING -> FREE
                     |                                  |
               real copy fence                  real Metal completion
               releases source barrier          permits IOSurface reuse
```

The independent A3 timer continues without network packets. Later vtest is
blocked until the real copy fence completes (zero-wait CPU poll); only then
can subsequent source writes/unrefs/reuse overlap the older Metal consumption.
This deliberately avoids relying on unvalidated cross-context GPU wait chains.
All GL/VirGL access stays on the serialized owner, restoring/unbinding EGL at
each call. No steady-state glFinish, GPU-to-CPU display copy, TRANSFER_GET or
remote frame ACK is introduced. Exceptional incomplete-copy teardown may drain
with glFinish, as in A3.1. Metal owns an independent IOSurface lease on cancellation.

Both slots share one Metal queue, submit in frame order, and initially permit
only **one Metal consumption at a time**. The other slot can copy/hold READY;
this is two-slot producer/display overlap, not two concurrent Metal consumers.
Layer configuration is not redundantly changed while the other drawable is
in use. A consumed slot keeps its context/IOSurface for reuse rather than
allocating every frame. Dimensions remain 64x64, formats 1/67, single sample,
level/layer 0, maximum 16 PRESENTs. nextDrawable may still incur an OS stall.

When copying or both slots are occupied, the unconsumed batch suffix remains
held. Only one admitted network batch (16MiB+64KiB, <=4096 envelopes) exists;
no resource/draw commands are dropped. Native per-phase deadlines are 10s.
This is not a total renderer resource budget; larger resources, sustained
throughput and comprehensive memory accounting remain later work.

## Evidence required on device

Use the Actions IPA with exact source/provenance. Select A3.2 and verify
`SCHEDULER=A3.2_ASYNC_DOUBLE_SLOT`; start a fresh 12-frame Ubuntu case using
the existing producer. Observe 30s live quiet hold (35s resources with explicit
cleanup margin), then user-disconnect and reconnect in the same app process.

Require: all changing images correct; ordered A32_ADMITTED/SNAPSHOT/COMPLETED
with consistent slot/generation; real resource info, producer/copy/Metal results
and GET=0; `allocated=2`, reuse on subsequent frames, no slot reuse before Metal
completion; `A32_POOL_CLOSE allocated=2 released=2` after normal idle shutdown.
The last frame must finish with no later packet and remain visible while idle.
Test GPU-in-flight cancellation separately; idle disconnect is not that test.

`A32_TIMING` is local observed/poll/setup-inclusive time, NOT GPU timestamps
or RTT. `iosurface_bytes_estimate` covers allocated color surfaces only, not
total GPU/renderer memory. `high_water` records actual occupied slots; normal
2fps traffic might never occupy both simultaneously. Correct ping-pong reuse
alone does not prove saturated backpressure/overlap on the phone; those need
an explicitly identified load/delay experiment, not invented FPS evidence.

CI preserves A1/A2/A3.1 regressions, adds actual native slot engine tests and
Swift ownership/order/cancellation tests. Linux software rendering and state
simulations are NOT iPhone double-buffer acceptance. No 720p/30, ten-minute
stability, crash recovery or Minecraft GL3.2/GLSL150 capability is claimed.
