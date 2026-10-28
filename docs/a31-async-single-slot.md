# A3.1: independent completion, single slot

Implementation batch, **device acceptance pending**. A2.1's accepted synchronous
mode remains the default. No double buffering, Minecraft, backend change,
new wire opcode, per-frame remote ACK, or performance target is added here.

## Ownership and bounds

`NativeRemoteDisplayConnection` selects the existing sync method or the new
native begin/poll methods. All EGL, VirGL, FBO and fence access is on the same
serial renderer owner queue. Every native call restores its EGL context and
unbinds on exit, because a Dispatch queue can change OS threads.

```text
ordered PRESENT -> pin resource + capture producer fence
  -> producer poll -> begin shared-context GPU blit
  -> copy poll -> release source pin -> submit Metal
  -> Metal poll -> retire IOSurface/copy context -> mark displayed
  -> release single-slot barrier -> resume the saved batch suffix
```

An independent, coalescing Dispatch timer drives progress every ~2ms; it does
not require a following network packet. `glClientWaitSync(..., 0, 0)` does not
CPU-wait. Metal is submitted then polled, without a completion wait loop.
`nextDrawable` itself is an OS drawable-acquisition call and may stall; this
batch does not claim that every driver/Metal API is nonblocking.

There is ONE in-flight PRESENT and ONE admitted batch, bounded by the existing
16MiB+64KiB / 4096-envelope limits. All later vtest, including resource UNREF or
handle reuse, stays behind the barrier until Metal completion. This deliberately
does not overlap later producer work with presentation yet. Tickets include a
monotonic generation, frame, resource and sequence; stale ticks cannot complete
a new resource incarnation. Existing strict 64x64 / maximum 16 PRESENT bounds
remain. There is no unbounded frame queue or GPU-resource-budget implementation
in this batch; those belong to A3.2/A3.3.

Each native phase has a 10-second local monotonic deadline. Cancellation stops
the timer, closes transport, returns the batch lease once and cleans native
resources. An incomplete GL copy can require an **exceptional teardown drain**
(`glFinish`); this is not used on the successful steady-state frame path.
Metal's completion handler owns an independent pixel-buffer/texture lease even
if cancellation happens before consumption. No CPU pixel mapping/copy,
`glReadPixels`, normal display TRANSFER_GET or video transport is added.

## Device procedure (all builds in Actions)

1. Install the new signed Actions IPA. Default mode is **A2.1 sync**. The
   existing one-click connection stores a profile only in device-only,
   when-unlocked Keychain. Host/port hints alone use UserDefaults. Clear/change
   it from test settings. Keep the same signing identity/access group; a
   re-sign/reinstall can change Keychain access and requires separate testing.
   No Token is embedded in the IPA/report or sent to cloud sync. Credential
   I/O runs off the UI and renderer queues; failure has no plaintext fallback.
2. Under **测试设置**, choose **使用 A3.1 单槽异步测试**, then one-click connect.
   Confirm `SCHEDULER=A3.1_ASYNC_SINGLE_SLOT`. This selection lasts only for
   the app process and does not modify formal renderer/provider settings.
3. Start a fresh existing 7-frame/1fps or 12-frame/2fps Ubuntu case with a
   >=120-second live hold. Do not change server deployment for this batch.
4. Record every changed image and the final held image. Save the full report:
   `A3_BEGIN`, exact ordered vtest/PRESENT IDs, resource info, producer fence,
   copy fence, Metal completion, `A3_COMPLETED`, counters and build provenance.
   The final frame must complete even when no further packet arrives.
5. Wait for a live >=120-second quiet checkpoint, actively disconnect and save
   cleanup evidence. Without quitting/reinstalling the app, start a fresh
   Ubuntu case and one-click reconnect without entering the Token again. This
   also covers the deferred A2.1 reconnect criterion; test sync mode as needed.
6. In separate sessions cancel while producer/copy/Metal is pending and confirm
   cleanup, then reconnect. Deterministic slow-GPU/cancellation device coverage
   is not claimed by the mock state-machine tests.

`A3_TIMING` reports **local observed phase times**, including timer scheduling,
context/IOSurface/pipeline setup and polling. They are neither hardware GPU
timestamps nor cross-device latency. There are no RTT/jitter/percentile/FPS/
memory performance claims yet. Existing A21_FRAME/HOLD lines are retained for
comparison; the A2.1 log checker must not be used to certify A3 device success.

## Automated evidence / boundaries

Swift tests exercise the actual independent timer, three-stage state/tickets,
timeouts, stale callbacks, bounded batch leases, cancellation and the strict
source-overwrite barrier. CI also compiles the real iOS UI and full native IPA.
The existing native Linux gate retains real pixel, shared-context GPU copy,
source overwrite, resource-lifetime, Core/GLSL 150 and legal application-readback
regressions. Linux software rendering and mock scheduling are NOT phone GPU
acceptance. Device correctness, cancellation/leaks and reconnect remain pending
until user reports; dual IOSurfaces and ten-minute performance remain later A3.
