# A2.1 multi-frame device acceptance, 2026-10-28

Evidence: user-supplied device reports, seven-frame screen recording, explicit
visual confirmations, and the corresponding Ubuntu diagnostic stdout. This
is a factual summary, not a fabricated raw report or CI device result.

Device: iPhone18,3, iOS 27.0.1 (24A446), Apple A19. Renderer pins and unsigned
framework hashes remain those in the accepted A2.0/A2.1 provenance. No change
to the approved backend or Mesa PRESENT protocol.

| Case | 7 application frames | 12 application frames |
| --- | --- | --- |
| App source | `9ed016c0f42c1c6abbf126ac7b5b67be324b789b` | `acce89631e7312bd93c6b8d1fcf51b5224fac599` |
| App Actions | [39124839349](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/39124839349) | [40638569598](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40638569598) |
| Session | `89802847-34C5-4B8D-916E-3F7BF67A80BE` | `062C1591-AD77-4E50-9166-B99387D4BCAA` |
| Completed PRESENTs, including startup | 8 | 13 |
| Final processed vtest sequence | 50 | 74 |
| Live quiet-hold checkpoint | 120.720 seconds | 120.061 seconds |
| Final SUBMIT / PUT / GET | 17 / 1 / **0** | 27 / 1 / **0** |
| User cancellation / cleanup returned | yes / yes | yes / yes |

Ubuntu twelve-frame log records `GL_RENDERER=virgl`, GL 2.1, GLSL 1.20,
`DRAW frame=0..11`, distinct RGB/offsets, and a 150-second resources-alive
hold. Its tools/proxy source is intentionally the accepted `9ed016c`, not a
silently selected main build; only the phone quick-connect UI changed.
PRESENT 1 is initialization; PRESENT 2..13 correspond to application draws.
The user confirmed the twelve-frame output was **correct and remained visible**.
The earlier seven-frame recording showed all seven changing triangles; the
subsequent full hold was explicitly confirmed by the user as always visible.

Both reports record producer/copy fence completion, Metal COMPLETED, correct
source pin/snapshot ordering and no display TRANSFER_GET. EGL `0x3000` means
success; GL error is `0x0`. Report durations include CPU setup and bounded
diagnostic waiting, and are NOT GPU-only times or WAN latency measurements.

Still pending: successful **same-process** full rendering after cleanup.
A later one-click session `32963DDD-5851-4EFE-A0E0-7C44308A8A56` reached QUIC
ready with zero vtest/PRESENT while the Ubuntu producer was not running.
This does not pass reconnect rendering, saved-token persistence across app
restart/re-signing, leak profiling, A3, or the guest GL 3.2/GLSL 150 gate.
The user deferred reconnect rendering to the next device test.

Subsequent evidence: the [A3.1 basic acceptance record](../a31-single-slot-2026-10-28/README.md)
now closes the specific same-process sync→async reconnect at app `a87970e`,
with actual frames and explicit user confirmation. The earlier QUIC-only
session above remains insufficient evidence by itself; historical records are
not rewritten as though that old session rendered.
