# A3.1 basic single-slot device acceptance, 2026-10-28

Verdict: **basic remote display, 30-second live hold, idle user-disconnect
cleanup and the specific same-process A2.1-sync → A3.1-async reconnect passed**.
Evidence is the user's full pasted reports and subsequent explicit confirmation
of correct images/hold and no app exit, reinstall or Token re-entry between
the two sessions, cross-checked against Ubuntu diagnostic stdout. This file
is an evidence summary, not a reconstructed raw report or CI device simulation.

## Build and execution provenance

- Accepted app source: `a87970e66cea636ce9db6e3834d85c9f19157102`.
- [App build 40708881150](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40708881150).
- [CI 40708880850](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40708880850): 27 Swift tests and policy/contract checks passed.
- [Linux native regressions 40708880582](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40708880582): separate software-renderer evidence, not phone acceptance.
- Renderer sysroot run `40636888480`, recipe source `61abde5f505165ff7200b2600a6cbaf7ea2f426c`.
- UTM `9d00a54833184628c696bcbfafbf344cea566e59`; virglrenderer `482f9d8b8c2d2288efa10a027116216909d2c226`; epoxy `bf98587477fe68d07b93319ece7b40a7d0e2eabe`; WebKit/ANGLE source `ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10`.
- Framework hashes and compatibility recipe remain those in the accepted A2.0/A2.1 provenance; no provider/version/capability override.
- Device: iPhone18,3, iOS 27.0.1 (24A446), Apple A19, ANGLE Metal GLES 3.0 / ESSL 3.00.
- Actual Ubuntu tools source `a87970e`; deployed proxy remains `9ed016c` and runtime Mesa artifact remains `38186021966`. These are explicitly separate from the refreshed tools dependency run `40676968489`, which uses the same dependency source pins. No latest-main substitution.

## Matched device and Ubuntu evidence

| Check | Observed |
| --- | --- |
| Async session | `8B6376E0-32C3-4BBE-8FD5-D1E96B87AF74` |
| Scheduler | `A3.1_ASYNC_SINGLE_SLOT` |
| Ubuntu renderer/shaders | Real `virgl`, GL 2.1 / GLSL 1.20, DRAW frame 0..11 with the expected distinct RGB/positions |
| Actual GPU source | Resource 1, tex_id 1, format 1, 64×64, depth 1, flags 0, stride 256, target 2, samples 0, array 1, level 0 |
| Completed frames | PRESENT 1..13, including startup; matching generation 1..13 |
| Exact afterSequence | 9, 15, 19, 24, 29, 35, 40, 44, 50, 55, 59, 65, 70; each equals processed sequence at PRESENT |
| Producer/copy/Metal | All 13 producer and copy fences complete; all 13 Metal consumptions complete; source pins released after snapshots |
| Error status | GL 0x0, EGL 0x3000 (SUCCESS); copy 0x911a means ALREADY_SIGNALED, not error |
| Final command/queue state | vtest 74; SUBMIT_CMD 27, TRANSFER_PUT 1, **TRANSFER_GET 0**; slot in_use 0, pending_envelopes 0, stage complete |
| Live checkpoint | last_present 13, completed 13, quiet_s **30.761**, live YES |
| Producer hold | 35 seconds resources alive (30-second requested observation + 5-second cleanup margin), HOLD_END and normal producer PASS |
| User disconnect | quiet_s 32.358 after cancellation; native cleanup returned and A21_SESSION_CLOSED |
| Visual confirmation | User confirmed every frame's position/color/orientation and that the last image stayed visible throughout the hold |

The report includes 13 A3_ENQUEUED / A3_BEGIN / A3_COMPLETED records with the
single-slot snapshot barrier held and released in order. Completion is driven
by the implemented independent timer; later vtest resumes only after Metal
completion. This is not producer/display overlap or double buffering.

Observed complete-PRESENT durations span 5.470–12.467ms for this finite
64×64, 2fps-sender run. These phone-local observations include polling/setup;
they are NOT hardware GPU timestamps, network latency, maximum throughput,
or proof of any sustained FPS target.

## Reconnect scope

The immediately preceding same-build sync report is session
`62613719-C0B7-4817-B751-5CB7F7745E85`: 13 completed PRESENTs, live quiet
30.469s, GET=0, active user-disconnect cleanup. The user explicitly confirmed
that switching from that session to the async session did not exit/reinstall
the app or require re-entering the Token. Actual rendering in the new session
therefore closes the previously deferred **specific same-process** cleanup,
EGL/VirGL reinitialization and saved-profile retrieval criterion.

This does not prove Keychain access after app restart/re-signing, repeated
same-mode stress reconnects, crash recovery, or cancellation during an active
producer/copy/Metal operation. Disconnect here occurred during idle hold.

## Still outside this acceptance

GPU-in-flight cancellation and failure injection; leaks/thermal or ten-minute
stability; dual IOSurface slot ownership/recycling; overlapping producer work;
larger resolutions; resource memory budgets and sustained performance remain
unaccepted/unimplemented as appropriate. Guest GL 3.2 Core / GLSL 150 remains
the separate known capability blocker. Minecraft/NeoForge, input and audio are
not accepted. No CPU framebuffer transport, video stream or phone JVM is used.

The accepted IPA's build-time header still says device acceptance pending;
this later user-confirmed record supersedes it for these narrowly listed gates,
not for the rest of A3 or graphics capability.
