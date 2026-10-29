# Device acceptance: native renderer gates

The available test device is user-reported iPhone 17 / iOS 27.0.1, with external
IPA signing available. Build only in GitHub Actions; do not compile on Ubuntu.
The first user screenshot showed an inverted local triangle; the subsequent
screenshot confirms corrected upward orientation. Native context/caps PASS,
GLES 3.0 works, and GLES 3.1/3.2 requests are rejected with EGL 0x3004. Guest
GLSL is 130 in both capsets, below the planned 150 threshold. These are local
observations, not remote draw or guest GL 3.2 Core acceptance. Repetition,
leak/thermal tests remain pending. These are the earlier LOCAL observations;
the later A2.1 single-frame and multi-frame evidence is recorded below:
the 7/12-frame image and live hold/cleanup gates passed,
while same-process render reconnect remains a separate pending test.

The app build at `816bf85` is retained in
[run 38245180997](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38245180997).
Future reports must identify the build/dependencies. Initialization PASS,
advertised caps and a screenshot timing overlay are not sustained FPS evidence.

1. Obtain the unsigned IPA from **Build iOS interop prototype**, using a
   successful **Build iOS renderer sysroot** built with the non-GBM external-EGL
   cleanup fix. Sign the complete app, including embedded EGL, GLESv2,
   virglrenderer.1 and epoxy.0 frameworks, using your provisioning method.
2. Install and launch. Tap **Render Probe**. Expect an orange triangle on a dark
   background, now pointing upward. Record any missing/corrupt/inverted image
   or reported ANGLE/IOSurface error.
3. Tap **VirGL Context + Caps**. Controls are disabled while the renderer runs
   on its own serial queue. Expect a native context/caps PASS report with host
   GL/GLSL/renderer strings and capsets 1 and 2, including full base64 dumps.
   The new report also records GLES 3.2/3.1/3.0 requests and actual versions,
   plus the decoded guest GLSL threshold warning. Failed higher-version requests
   are useful capability evidence; they must not be hidden or overridden.
4. Tap **Share Report** to copy/export the complete report (a screenshot alone
   truncates capsets). Repeat the native gate five times and switch back to
   **Render Probe**; both modes must still work without a crash. Repetition
   exercises initialization and ownership cleanup but does not measure leaks.
5. Return the full reports, triangle observation, device/OS versions and any
   crash log. Actual sustained resource/memory and GPU validation requires
   device profiling later; these one-shot diagnostics do not establish it.

Use **Connect Capability Probe** for the separate
[Ubuntu capability test](../docs/iphone-capability-probe.md). It connects to
Ubuntu but deliberately rejects remote presentation and readback. A successful
host/native diagnostic does **not** pass guest GL 3.2 Core: the following gate
must connect Mesa virpipe from Ubuntu and create that exact Core context through
the iPhone renderer. This is necessary before Minecraft, **not** before route
A's low-capability remote triangle. No JVM/Minecraft launcher belongs here.

## A2.0 single-frame VirGL resource interop

**Accepted on device at `98e65d1878ea132dbf4cb169e521facdc62f04a6`.** The user
supplied the full completion report and correct four-color screenshot on
iPhone18,3 / iOS 27.0.1. No magenta overwrite, inversion or channel swap was
observed. Keep the following procedure for regressions, not as a claim that
new A2.1 network display or sustained leak testing already passed.

Build **Build iOS interop prototype** on `feature/a2-single-frame-interop`, with
explicit `renderer_run_id=38206257487`. The artifact name includes the app SHA;
do not install an older main-branch IPA. Sign the IPA **and all embedded
frameworks** as above. Compilation is not device acceptance.

Tap **A2.0 VirGL Resource → IOSurface** (not Render Probe). It runs a one-shot
native vtest resource fixture, not a network session. The source image is made
by VirGL GPU clear/copy commands, not by local GLES triangle drawing.

Expected image on a dark 640x360 background:

- Upper-left: RED, tall rectangle (160x108).
- Upper-right: GREEN, short rectangle (140x60).
- Lower-left: BLUE, small rectangle (100x80).
- Lower-right: YELLOW, wide rectangle (220x100), with dark margins.

Check all colors, relative positions, edge/margin sizes and absence of flipped,
stretched or stale triangle content. Metal applies the existing single
orientation transform; the GPU copy does not flip or manually swap channels.
The later reused source is GPU-cleared MAGENTA before display: magenta instead
of the four-color pattern indicates broken snapshot isolation and is a FAIL.

Share the **entire report and screenshot**. Report must show actual app/source
and renderer provenance, device/OS, resource 42 / format 67 / 640x360 / flags 0,
shared texture visibility, complete source/destination FBOs, GL/EGL success,
producer and copy fence completion, Metal COMPLETED, pin/final-release/handle
reuse and teardown. `TECHNICAL CHECKS COMPLETED` alone is not visual acceptance.
Any failure must preserve its stage/errors; never retry via CPU framebuffer.

Repeat five times and alternate with **VirGL Context + Caps** / **Render Probe**.
Report crashes, hangs, corruption and whether last image remains visible after
the report returns. This exercises teardown; sustained leak/thermal profiling
and continuous remote PRESENT remain separate future tests. No Ubuntu session,
Minecraft, or network configuration is needed for A2.0.

Source/interface details and CI-only readback boundary:
[A2.0 implementation](../docs/a2-single-frame-interop.md).

## A2.1 real Remote Display (single and 7/12 frames accepted; reconnect pending)

User-confirmed single-frame baseline `3b5e80d25f04de4b96b3c3ed2381537ba90b57ed`,
Actions app `39101559555`, iPhone18,3 / iOS 27.0.1 (24A446). Ubuntu frame 0
matched the screenshot; PRESENT 1/2 and all producer/copy/Metal completions
succeeded with TRANSFER_GET=0. This supersedes earlier statements about
end-to-end display pending, not the separate guest GL 3.2/GLSL 150 blocker.

Use **Connect Remote Display** and follow the exact isolated proxy / one-frame
producer / report / live-hold / cancellation steps in
[A2.1 device procedure](../docs/a21-remote-present.md#device-procedure).
The capability connection still rejects PRESENT; the A2.0 button still runs a
local fixture. Neither can substitute for the new mode's actual Ubuntu frame.
Start with one application frame, then 7/12 only after its visual acceptance.
The first frame is accepted; now follow the
[multi-frame batch procedure](../docs/a21-remote-present.md#a21-final-multi-frame-batch).
Use its NEW IPA for per-PRESENT completion, a unique session ID, quiet-hold
checkpoints and cleanup evidence. Record all changing frames, wait for live
quiet_s >= 30 by default (or the case's explicitly requested longer duration),
Disconnect, save the cleanup report, then reconnect without
restarting the app. Do not count a retained image after disconnect as live hold.

## Route A: A3.1 single-slot async (basic device gates accepted)

The A2.1 7/12-frame image/120-second live-hold/active-cleanup cases are
[device accepted](../docs/evidence/a21-multiframe-2026-10-28/README.md).
The subsequent [A3.1 device report](../docs/evidence/a31-single-slot-2026-10-28/README.md)
at `a87970e` accepts correct 12-frame async display, 30-second live hold, idle
cleanup and specific same-process sync→async rendering without Token re-entry.
GPU-in-flight cancellation, repeated reconnect stress and leaks remain pending.

For the next IPA select **测试设置 → 使用 A3.1 单槽异步测试**, then use
one-click connection. Default remains A2.1 synchronous. Follow the exact
[A3.1 device procedure](../docs/a31-async-single-slot.md#device-procedure-all-builds-in-actions),
including last-frame completion without new packets, live hold, cancellation
and same-process reconnect. Do not mistake scheduler unit tests or a successful
IPA build for phone acceptance. A3.1 still uses one slot, pauses all later
vtest and keeps the 64x64/16-PRESENT diagnostic limits. A3.1 itself has no double
buffering; the separate A3.2 implementation below has basic device acceptance. Resource
budgets, ten-minute stress and throughput acceptance remain later work.
New live-hold observations default to 30 seconds; the producer adds five seconds
of explicit resource cleanup margin. The app keeps 30/60/90/120... checkpoints.
Previously accepted 120-second cases remain historical evidence, not shortened
or replaced by the new default.

Follow [route A tasks](../docs/next-stage-plan.md#route-a-remote-present-poc).
Use a new Actions-built low-capability demo, preserving existing Core/GLSL 150
tests. Begin with a small single-sample RGBA/BGRA 2D target and GL 2.1 / GLSL
120 if genuinely available. No version overrides or application software fallback.

1. Extend the existing **Connect Remote Display** mode on an independent A3
   branch, preserving synchronous A2.1, not **Connect Capability Probe**.
   Record Ubuntu shader/draw logs and phone received vtest/PRESENT sequences.
   The phone must not generate the triangle vertices or animation.
2. Display changing position/color plus an Ubuntu-encoded application-frame
   pattern. Check a finite sequence and frame order. PRESENT IDs include
   possible initialization flushes and need not equal application frame IDs.
3. Show the last frame after traffic stops. Stress repeated source writes,
   UNREF/reuse and delayed display; already captured content must not change.
4. Require zero normal-display TRANSFER_GET and no full-frame GPU->CPU fallback.
   OS screenshots/screen recordings for inspection are not the render transport.
   Explicit application-readback compatibility remains a separate test.
5. Extend to 10 minutes without corrupt frames/crashes or sustained resource
   growth. Report queue high-water marks, snapshot slots, resource references,
   fence/Metal completion and disconnect cleanup. No initial 720p/30 threshold.

Reject local-only triangles, missing VirGL-resource snapshots, completion that
needs a later packet, or normal framebuffer readback to Ubuntu. A PASS proves
remote rendering/presentation, not Minecraft capabilities.

## A3.2 double-slot acceptance (finite basic gates passed)

The [accepted `6dd8b04` device cases](../docs/evidence/a32-double-slot-2026-10-28/README.md)
include normal retirement and the separate 750ms diagnostic, with correct
12-frame images, 13 completed PRESENTs, >30s live quiet hold, GET=0, two
allocations / eleven reuses, and both slots released. Diagnostic high_water=2
proves actual saturation in that case. Normal idle user-disconnect passed;
the diagnostic ended instead at producer EOF (phone POSIX 54), with cleanup
returned. Do not relabel it user cancellation or erase the startup stall.
The following remains the reproducible regression procedure, not a claim of
ten-minute performance, GPU-in-flight cancellation or crash recovery.

Use the new Actions-built IPA and choose **测试设置 → 使用 A3.2 双槽异步测试**.
Require `SCHEDULER=A3.2_ASYNC_DOUBLE_SLOT`, then use a fresh 12-frame Ubuntu
case and 30-second live hold. Save the changing images and full report before
and after disconnect. Both slots must allocate once and be reused only after
Metal completion; final `A32_POOL_CLOSE` must release both slots. Require GET=0,
strict frame/slot/generation sequence, no source overwrite before snapshot and
normal final-image retention. A2.1/A3.1 remain selectable regression modes.

Then choose **A3.2 背压诊断（回收延迟 750ms）** for a second fresh session.
The delay is an explicit timer-driven hold AFTER real Metal completion, not
artificial GPU work; require high_water=2 and correct bounded recycling.
Frame/UI durations include this policy, so do not treat them as GPU/FPS data.
GPU-in-flight cancellation and long-run stability still need separate tests.
See [full A3.2 ownership/procedure](../docs/a32-double-surface.md).

## B1.1 standalone Provider/Context Probe (device accepted, limited scope)

Install the separately signed **RemoteGPU B1.1** IPA, bundle
`org.remotegpu.experiments.mobileglues`, alongside the accepted RemoteGPU App.
[Build/IPA/source evidence](../docs/evidence/b11-build-2026-10-28/README.md)
at source `ff4fae6`, Actions `40783974009`. No Ubuntu connection, service
restart, pairing Token or Remote Display test mode is needed.

Latest accepted B1.1 source is `d95d32b`, Actions `40816895275`, on iPhone18,3
/ iOS27.0.1. [Device evidence/provenance](../docs/evidence/b11-device-2026-10-29/README.md)
records real shared-content/migration/return and cleanup success. Earlier builds
below retain their failures for reproducibility; do not use their pending status
as the latest verdict. B1.2 shader/features and guest GL remain untested.

Tap **Run Provider + Context Probe**, wait for PASS/BLOCKED, then
**Share Full Report**. Run once per process; relaunch only this independent
Probe to repeat. If it crashes, preserve its actual crash log rather than
reporting a completed test. Do not replace the accepted RemoteGPU app.

Require all four actual GL/EGL provider identities and function ownership,
explicit bootstrap result, frontend and actual backend strings (metadata only),
create/share/make-current/unbind/destroy results, verified shared GPU-clear
content, worker-thread migration/return and cleanup errors. Up to three 1x1
offscreen reads are content-test oracles, not a display/transport path. No
GLSL150 shader or guest GL3.2 capability verdict follows from this B1.1 report.
See [implementation and reproducible procedure](../docs/b11-mobileglues-probe.md).
Device follow-up at `59c7001` / `40785620860` confirmed bootstrap/provider
checks but stopped at a missing direct `eglGetPlatformDisplayEXT` export.
Correction `8c5a943` / Actions `40816036011` passed CI/build and shares
bootstrap's validated ANGLE proc-table selection with the App. Use the new
IPA linked in the implementation procedure. In a fresh Probe process, capture the selected route/provider,
then actual context, sharing, migration, pixel checks and cleanup. CI policy
fixtures do not substitute for those device results; do not mark B1.1 passed yet.
Device report at `8c5a943` now confirms the proc-table provider/display and both
context creations/root binding. It stopped at the Probe's invalid EGL minor
query (0x3004), before content/migration. The next App-only correction uses EGL
client/config and GL version/profile queries; those returned versions remain
metadata, especially because the candidate profile getter is a fixed Core bit.
Capture `context_metadata_correct_api`, all actual GPU content/migration results
and cleanup. No server restart or candidate backend replacement is involved.
Ready-for-retest build: code `d95d32b`, Actions `40816895275`, with CI `40816895381`
passed. Use the latest retest IPA link at the top of the B1 implementation page,
not the retained earlier failure builds. Candidate/ANGLE hashes are unchanged.

## Route B: subsequent shader and guest capability gates (unaccepted)

Investigate MobileGlues + ANGLE Metal first, then MobileGL iOS interfaces, then
UTM MoltenVK with a suitable GL/Vulkan compatibility implementation. Build one
candidate probe at a time in Actions, isolated from route A. Do not modify
existing ADRs or formal renderer selection merely because a probe builds.

Require iOS ARM64 link/install, explicit GL/EGL provider/context ownership,
actual GLSL 150 compile/translation/execution, and functional FBO/VAO/
instancing/texture-buffer/depth/sync tests. Record geometry-stage simulation
and other gaps individually. Linking, symbol lookup and version strings are
not execution verdicts; missing required features are BLOCKED/FAIL.

Then exercise the candidate through virglrenderer and Ubuntu Mesa. Host-native
desktop GL is not required if the chain implements the virtual desktop GL
semantics, but guest Core-context creation and real shaders/draws must pass.
Never substitute GL_VERSION, GLSL_VERSION or cap-bit overrides for implementation.
Route A's A2.1 multi-frame and A3.1/A3.2 basic gates are accepted as recorded above;
the remaining A3 gates and route B remain unaccepted.
See [the interface investigation/task plan](../docs/next-stage-plan.md).
