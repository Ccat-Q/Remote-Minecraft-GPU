# B1.1 isolated MobileGlues provider/context probe

Experimental branch `experiment/b11-mobileglues-probe`, based on accepted
A3.2 source `6dd8b04` and its later evidence record. No production renderer,
protocol, DNS, server deployment or ADR is changed. All compilation is Actions-only.

Build/link/packaging and retained regressions now passed at `ff4fae6`.
[Exact Actions/IPA/source evidence](evidence/b11-build-2026-10-28/README.md).
Device execution at `ff4fae6` is **PARTIAL / BLOCKED**: the user confirmed
successful bootstrap (384 backend resolutions) and seven frontend direct/proc
ownership checks, then a generic dladdr failure before frontend context creation.
The corrected diagnostic is pending device retest. No context/sharing PASS or
desktop GL capability is claimed. See the retained device report below.

## Implementation boundary

Separate bundle `org.remotegpu.experiments.mobileglues`, not a mode of the
formal RemoteGPU app. It embeds only MobileGluesProbe, EGL and GLESv2; no
virglrenderer or epoxy. It has no network connection, launcher or JVM.
MobileGlues is pinned to `97558a69157b033b890958b1e49258c5b51a80c6` and all
required shader/hash dependencies to their recorded gitlinks. ANGLE is reused
from verified renderer run `40636888480` without rebuilding or renaming it.

`prepare_mobileglues_probe.py` rejects changed source hashes/revisions. Its
isolated source adaptation replaces constructor startup with an explicit,
one-attempt bootstrap, selects ANGLE Metal explicitly, releases the temporary
bootstrap context on Apple, and disables the upstream Apple error-ignore
policy. It does not change GL/GLSL versions, feature implementations or caps.
The replacement Apple CMake recipe keeps upstream compilation units and
shader dependencies but removes GNU linker flags and accidental GL linkage.
Three unsupported Mach-O framebuffer aliases become equivalent forwarding
exports, and EGL trace thread IDs use the Apple pthread API instead of an
Android syscall. These are platform adaptations, not new GL features.

The app uses absolute framework paths and `RTLD_FIRST | RTLD_LOCAL | RTLD_NOW`.
Frontend GL/EGL symbols and proc lookup must resolve to MobileGlues; backend
symbols must resolve to the distinct ANGLE EGL/GLES images. The backend
resolver checks `dladdr` for every resolved pointer; optional missing GLES
symbols stay missing. There is no global-provider or system-GLES fallback.
Framework images stay process-resident: unsafe unloading of C++/TLS state is
not a cleanup strategy. Contexts, texture, FBOs and surfaces are cleaned up
separately and their errors are reported.
ANGLE's exported EGL wrappers and its `EGL_*` proc-table implementations can
live in different installed ANGLE images; both are identified explicitly.
OS-preloaded GLES images are reported, not confused with the actual selected
function providers. Their mere presence is not a binding failure.
The selected exported `eglGetPlatformDisplayEXT` entry is mandatory and strictly
validated. Its duplicate `eglGetProcAddress` query is an optional diagnostic:
NULL is recorded as UNAVAILABLE, not a passed lookup or missing GL feature.
A non-null result still requires a resolvable identity in one of the exact
installed ANGLE images; unresolved/foreign pointers fail closed. Symbol names,
NULL versus dladdr errors, addresses, EGL errors and stage markers are retained.

## Build and test

Run **Build isolated iOS MobileGlues probe** on the experiment branch with
`renderer_run_id=40636888480`. The workflow verifies the renderer link gate,
applies guarded source changes, builds only the candidate for iOS ARM64,
checks exports/linkage, builds the independent unsigned IPA, and publishes
full logs, hashes, recipe and modified LGPL corresponding source plus licenses.
Exact framework results and partial compiler results are cached separately;
the verified candidate is saved before app packaging, including when a later
app step fails. Packaged unsigned binaries must match the recorded hashes.
ANGLE/Mesa are not rebuilt. Source guard/isolation unit tests run in CI.

Install the externally signed **RemoteGPU B1.1** app alongside the accepted
RemoteGPU app. No server restart or pairing token is required.

1. Tap **Run Provider + Context Probe**, once per process; relaunch to repeat.
2. Share **Full Report**, including any BLOCKED result or runtime error.
3. Verify actual source/run/framework provenance and four provider identities,
   then bootstrap resolution, frontend proc ownership, create/shared contexts,
   make-current, unbind, worker-thread migration and return, and cleanup.
4. Shared-content checks compare a real GPU clear through a new FBO in each
   context. Three 1x1 diagnostic reads are local test oracles, not display
   transport or a CPU framebuffer display path. One-shot `glFinish` is a
   conservative diagnostic only, not proposed steady-state scheduling.

The frontend 3.2 Core context request and version/profile strings are explicitly
**metadata, not semantic acceptance**. B1.1 does not yet compile GLSL 150,
test full desktop features, integrate VirGL or pass Ubuntu guest GL 3.2.
B1.2 actual shader/feature draws and then a separately gated B1.3
dispatch integration are subsequent gates. CI compile/link success is not
device bootstrap or feature success. Keep failures and missing features;
never convert them into simulated PASS results.

## First device report (retained failure, not acceptance)

The user supplied a full report from iPhone18,3 / iOS 27.0.1 (24A446), app
source `ff4fae65b068409964fc5b45d688b7abe95a23ee`, run `40783974009`, unchanged
candidate framework `47fafd8b923cefd1c8c28e11b580ba01a8f2b716e5877d8c8f2e14d178399f2c`.
This is a summary of that report, not reconstructed raw device output.

- Frontend GL/EGL owners: the bundled MobileGluesProbe framework.
- Backend EGL/GLES owners: the bundled EGL and GLESv2 frameworks respectively.
- System OpenGLES images were preloaded by the OS, explicitly NOT selected.
- Explicit bootstrap result 0, empty error, 384 resolved backend entries.
- All seven reported frontend direct/proc identities matched: eglCreateContext,
  eglMakeCurrent, eglGetProcAddress, glGetString, glBindTexture,
  glFramebufferTexture2D, glReadPixels.
- Cleanup released the owner thread successfully (EGL 0x3000).
- Failure: `BLOCKED: dladdr provider identity unavailable`; no frontend display,
  context, sharing, migration or pixel-result line was reached.

The code location is the subsequent platform export/duplicate-proc ownership
check. Bootstrap already used the validated exported platform entry; requiring
the additional unused proc-table route was an erroneous extra prerequisite.
The old generic error does not itself distinguish NULL from a non-null pointer
whose image could not be resolved. The new report must provide that distinction;
do not invent a device NULL result or call this a driver/MobileGlues feature failure.
