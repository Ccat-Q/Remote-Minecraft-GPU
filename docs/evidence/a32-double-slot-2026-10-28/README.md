# A3.2 basic double-slot device acceptance, 2026-10-28

Verdict: **finite 12-frame remote display, persistent two-slot reuse, 30-second
live last-image hold and the separate saturated-retirement/backpressure
diagnostic passed**. The user supplied both complete device reports and
explicitly confirmed the changing images' colors, positions, orientation and
last-image visibility for each case. This is a summary of those reports and
server logs, not a reconstructed raw report or simulated device result.

## Provenance

- Accepted app source: `6dd8b04c049da999b9dbd91e4c341f4a8b6d5e31`.
- [App Actions 40716006126](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40716006126).
- [IPA artifact 12828481287](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40716006126/artifacts/12828481287), unsigned IPA SHA256 `ef1eb2ba1a2a7c3d554d216ff109acef5eb65fe49cf86948ca71162cc077ae57`.
- [CI 40716003481](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40716003481): 32 Swift tests, native slot-engine sanitizer and contract checks.
- [Native rendering gate 40716003438](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40716003438): real Linux dual-snapshot/resource-reuse oracle plus retained regressions; separate from phone acceptance.
- Renderer sysroot Actions `40636888480`, recipe source `61abde5f505165ff7200b2600a6cbaf7ea2f426c`.
- UTM `9d00a54833184628c696bcbfafbf344cea566e59`; virglrenderer `482f9d8b8c2d2288efa10a027116216909d2c226`; epoxy `bf98587477fe68d07b93319ece7b40a7d0e2eabe`; WebKit/ANGLE `ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10`.
- Compatibility recipe SHA256 `ac13a6cf81f3c4273d6e1a34ee62d9c38c0e9e09103c31895761cd0019cd23fe`; frameworks unchanged from accepted A2/A3.1, no provider or capability override.
- Device: iPhone18,3, iOS 27.0.1 (24A446), Apple A19; ANGLE 2.1.22612 (`40dfb3a8bd65`) Metal, host GLES 3.0 / ESSL 3.00.
- Actual Ubuntu tools source `a87970e66cea636ce9db6e3834d85c9f19157102`, deployed proxy `9ed016c`, runtime Mesa artifact `38186021966`; refreshed tools dependency run `40676968489` uses the same pinned Mesa source `590bf21d918c86908d96d1f4590ecd25b9657171`. These are explicitly distinct component builds, not latest-main substitutions.
- Previous accepted device baseline: [A3.1 `a87970e`](../a31-single-slot-2026-10-28/README.md); A1/A2 provenance remains in the device reports and earlier evidence records.

## Matched results

| Check | Normal retirement | 750ms diagnostic retirement |
| --- | --- | --- |
| Session | `27B23257-E171-4374-A5BA-A846F9814930` | `B739F671-3C34-4746-9442-92757C17D047` |
| Scheduler | `A3.2_ASYNC_DOUBLE_SLOT` | `A3.2_ASYNC_DOUBLE_SLOT` |
| retirement_delay_ms | 0 | 750 |
| Completed PRESENTs | 1..13, including startup | 1..13, including startup |
| Source | handle 1 / tex_id 1, format 1, 64x64, stride 256, depth 1, flags 0, target 2, samples 0, array 1, last_level 0 | Same supported resource shape |
| Slot ownership | Alternating slot 0/1, matching generations 1..13 | Same; next slot admitted/snapshotted before older slot retirement |
| Producer / copy / Metal | All completed, GL 0x0 and EGL 0x3000 (SUCCESS) | All completed, GL 0x0 and EGL 0x3000 (SUCCESS) |
| Source safety | Source barrier released only after copy completion | Same, while the older IOSurface remains owned |
| Pool high_water | 1: ping-pong reuse, not saturation | **2: both slots actually occupied** |
| Pool allocation / reuse / retirement | 2 / 11 / 13 | 2 / 11 / 13 |
| Final occupied / source barrier | 0 / NO | 0 / NO |
| Color-surface estimate | 32768 bytes, not total renderer memory | 32768 bytes, not total renderer memory |
| Received vtest / reply bytes | 4434 / 1900 | 5718 / 1900 |
| Batch high-water bytes | 1336 | 1380 |
| Final vtest sequence | 74 | 81, includes producer teardown commands |
| SUBMIT / PUT / GET | 27 / 1 / **0** | 29 / 1 / **0** |
| Live quiet checkpoint | **30.775s**, last_present=13, completed=13 | **30.037s**, last_present=13, completed=13 |
| End condition | User cancelled during idle hold | Server closed after producer hold/teardown; phone reported POSIX 54 |
| Cleanup | allocated=2, released=2, cancelled_frames=0; native cleanup returned | Same, pending_envelopes=0; native cleanup returned after remote closure |
| Visual verdict | User explicitly confirmed correct sequence and visible last frame | User explicitly confirmed correct sequence and visible last frame |

Both paths use actual Ubuntu GL 2.1 / GLSL 120 draws through virpipe, vtest,
ordered QUIC, native decoder, real VirGL resource snapshot, shared EGL,
GPU Blit, IOSurface and Metal. No phone-local triangle fixture or display
CPU readback is used. Two persistent allocations and eleven reuses are
observed rather than inferred from the existence of two configured slots.

## Preserve anomalies and evidence limits

The normal case's startup PRESENT had `metal_observed_ms=823.518` and complete
PRESENT duration 912.932ms. Subsequent complete-PRESENT observations ranged
4.865..7.924ms. Preserve the startup stall for later attribution; these local
poll/setup-inclusive observations are not pure GPU time, RTT, or sustained FPS.

The delay case deliberately retains a slot for another 750ms **after observing
real Metal completion**. Its roughly 714..724ms READY waits and roughly
750..752ms retirement observations are policy-induced queueing, not simulated
GPU execution. It proves the exercised full-pool backpressure and ordered
reuse, not behavior under a physically slow GPU or GPU-in-flight cancellation.

The delay case ended with `NETWORK FAILED: POSIXErrorCode(rawValue: 54)`.
At 15:46:33 UTC the server logged `bridge vtest/PRESENT: EOF` and QUIC
application close code 0, reason `session closed`. The producer logged
`HOLD_END` and its normal PASS after the configured 35-second resource hold;
the proxy remained running. `tests/gl_remote_present.c` destroys its window
after the hold, and `internal/proxy/bridge.go` closes QUIC when the bridge ends.
This is producer-end/connection-close behavior, not evidence of a GPU fault
or a successful **user-initiated** disconnect in that case. The phone's final
`quiet_s=0.025` followed teardown traffic and does not erase its earlier live
30.037s checkpoint. Graceful producer EOF classification remains follow-up
work; POSIX 54 alone must not be generalized to arbitrary network failures.

Idle user-disconnect cleanup passed in the normal case; remote-end cleanup
passed in the delayed case. No assertion is made about app restart, same-mode
reconnect stress, crash recovery, GPU-in-flight cancellation, driver leaks,
thermal stability, ten-minute operation, larger resolutions or sustained
throughput/resource budgets. Guest GL 3.2 Core / GLSL 150 and Minecraft remain
separate unpassed gates. Existing A2.1 and A3.1 results are unchanged.

The installed app's build-time pending header predates this explicit user
acceptance. This record supersedes that header only for the finite basic
tests listed here; it does not pass the rest of A3 or route B.
