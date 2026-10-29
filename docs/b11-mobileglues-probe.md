# B1.1 isolated MobileGlues provider/context probe

Experimental branch `experiment/b11-mobileglues-probe`, based on accepted
A3.2 source `6dd8b04` and its later evidence record. No production renderer,
protocol, DNS, server deployment or ADR is changed. All compilation is Actions-only.

Build/link/packaging and retained regressions now passed at `ff4fae6`.
[Exact Actions/IPA/source evidence](evidence/b11-build-2026-10-28/README.md).
Latest device execution at `d95d32b` **PASSED B1.1 ONLY**: checked Provider chain,
context creation, shared GPU-clear content, exclusive worker migration/return
and cleanup calls. [Device evidence and full provenance](evidence/b11-device-2026-10-29/README.md).
Desktop GL/GLSL semantics, VirGL and guest GL are not accepted. All previous
failures and their correction builds are retained below.
Accepted B1.1 IPA: [context-metadata correction at d95d32b](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816895275/artifacts/12872158793).

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
Bootstrap and App now share one platform resolver. It first checks the direct
`eglGetPlatformDisplayEXT` export; if absent, it queries the checked backend
`eglGetProcAddress`. Direct exports must belong to the exact installed EGL image;
proc entries must belong to the exact installed EGL or GLESv2 image. No frontend,
global or system-provider fallback exists. Both entries absent, non-null without
identity, or foreign identity fail closed. A foreign direct export cannot trigger
fallback. A checked, exception-contained ABI exposes this same Metal display
acquisition to the App only after successful bootstrap. Reports identify route,
pointer, provider, display, EGL status and stages; context tests remain mandatory.

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

The old generic error did not distinguish NULL from a non-null pointer whose
image could not be resolved. The earlier inference that bootstrap used a direct
export was incorrect: the next device report proves that export is absent.
Source/header availability is not evidence of a binary export. Neither report
establishes a driver/MobileGlues feature failure.

### First correction build (device failure retained)

- Source `59c7001bb93b6d7c93994e72507034fdfffce73a` on the same experiment branch.
- [IPA Actions 40785620860](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40785620860), [IPA artifact 12859780300](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40785620860/artifacts/12859780300), [diagnostics/source 12859141498](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40785620860/artifacts/12859141498).
- [CI 40785620766](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40785620766) passed, including the actual `ProviderPolicy.hpp` compiled with ASan/UBSan. Its absent/known/foreign/unresolvable pointer fixtures test the policy, not iPhone dladdr or rendering.
- IPA SHA256 `59dee3113d9a816f6d9a039911b4e25268a66c3f2a8729d5e28f4249db62bfbc`; ZIP integrity and embedded source/run checked.
- Candidate framework SHA256 remains `47fafd8b923cefd1c8c28e11b580ba01a8f2b716e5877d8c8f2e14d178399f2c`; recipe/overlays, ANGLE and formal route A renderer are unchanged. Only the Probe app and tests changed, with verified dependency caches reused.

Device report from the same model/OS at `59c7001`, run `40785620860`:

- Bootstrap succeeded with 384 resolved entries and the same seven frontend identities.
- Stage `resolve_platform_export_and_optional_proc` failed with
  `dlsym eglGetPlatformDisplayEXT: symbol not found` in bundled EGL.framework.
- Owner-thread release returned 1 / EGL 0x3000; no frontend contexts were created.
- This disproves the prior direct-export assumption. Bootstrap has already used
  its checked proc-table route; the App's independent mandatory-export check was
  the erroneous additional prerequisite, not evidence of missing desktop GL semantics.

### Shared-resolver correction (Actions passed, device progressed to metadata error)

The resolver policy is now in `Overlay/Bootstrap.h`, used by the actual candidate
bootstrap and App acquisition ABI. CI compiles that same policy with ASan/UBSan:
valid direct export, absent export with valid EGL/GLES proc entry, both missing,
unresolvable/foreign identity, invalid anchors, and no fallback from a bad export.
These are policy fixtures, not simulated iPhone execution. The candidate must be
rebuilt because its ABI changed; ANGLE remains the exact accepted artifact.

- Code `8c5a943e48ffdf6108e59a5d807dba1160f8e075`, branch `experiment/b11-mobileglues-probe`.
- [iOS Actions 40816036011](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816036011) **passed**: candidate ARM64 build, new ABI export, provider/link isolation, independent app and IPA packaging, exact unsigned bundle hash checks. All compilation occurred in Actions.
- [Self-signable IPA artifact 12872507543](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816036011/artifacts/12872507543).
- [Diagnostics and LGPL corresponding source 12872512159](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816036011/artifacts/12872512159), including exact candidate adaptations, toolchain, build/link logs, dependency pins and full provenance.
- [CI 40816036028](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816036028) **passed**: shared platform policy ASan/UBSan, existing native vtest and double-slot ownership tests, 8 B1 Python source/isolation tests, 32 Swift tests, Linux proxy/protocol and Mesa patch gates. These do not prove iPhone context or shader behavior.
- IPA SHA256 `ceb1ddae83c4e57cf254e4d5f36af66c9a9c6ffd1cda161e3ba5aba932eb283e`; downloaded ZIP integrity and embedded source/run verified.
- New unsigned candidate framework SHA256 `63f17c59ff480b7cd71463f901f28f76611a3a40bba6e9d9dbd37d63d8f1b6c0`. The ABI change intentionally changes the candidate binary; ANGLE EGL/GLESv2 hashes remain the accepted values. The provenance sysroot also lists epoxy/VirGL, but neither is embedded in this App.

Changed files: `Overlay/Bootstrap.{h,cpp}` (shared selection policy/checked ABI),
`App/Probe.mm` (reuse resolver and report route), the two Actions workflows,
actual policy test and Python guards. The obsolete App-only policy was removed.
Docs and device procedure now distinguish both retained failures from pending
context acceptance. No formal renderer, dependency revision or ADR was changed.
There is no new performance result. The subsequent device report below confirms
context creation, not shared-content/migration or B1.2/guest GL acceptance.

Update **only the independent B1.1 app**, launch a fresh process and share Full
Report. Expect `acquire_metal_display_shared_resolver`, a verified
`ANGLE_PROC_TABLE (direct export absent)` owner, then actual frontend display,
context/sharing, worker migration, three pixel checks and cleanup results.
Any later failure stays BLOCKED with its stage; B1.2 and guest GL remain untested.

### Device report at 8c5a943 (metadata query failure retained)

Summary of the user's actual iPhone18,3 / iOS 27.0.1 (24A446) report, not a
reconstructed raw log. Source/run/candidate hashes match the shared-resolver
delivery above; accepted ANGLE artifact is unchanged.

- Bootstrap 0 / 384 entries, seven frontend direct/proc identities matched.
- Shared display acquisition succeeded, route 2, pointer owned by the bundled
  **GLESv2** image, not system GLES. Both acquisition EGL statuses were 0x3000.
- Frontend initialize, bind virtual desktop API, choose config, pbuffer,
  root/shared context creation and root make-current succeeded (EGL 0x3000).
- Frontend reported `4.0.0 MobileGlues 2.0.0` / `4.00 MobileGlues with glslang and SPIRV-Cross`.
  Backend still reports actual GLES 3.0 / GLSL ES 3.00 / ANGLE Metal A19.
  These strings do not prove GL 4.0, GL 3.2 or any shader semantics.
- EGL major query succeeded; minor query returned 0 / 0x3004 (EGL_BAD_ATTRIBUTE).
  Execution stopped before profile, GPU content or thread migration tests.
- Unbind, destroy shared/root/pbuffer, terminate and release owner thread all
  returned 1 / EGL 0x3000. No resource-sharing or leak-profile PASS is inferred.

Root cause is in the Probe, not evidence of missing context creation:
[EGL QueryContext](https://raw.githubusercontent.com/KhronosGroup/EGL-Registry/main/sdk/docs/man/eglQueryContext.xml)
accepts client type/config attributes, not the minor/profile creation attributes.
[KHR_create_context](https://raw.githubusercontent.com/KhronosGroup/EGL-Registry/main/extensions/KHR/EGL_KHR_create_context.txt)
directs version/profile queries to `glGetIntegerv`. The pinned frontend
`egl/egl.cpp:821` first forwards the query to ANGLE; rejecting the invalid EGL
query is not a reason to fabricate a supported attribute in the compatibility layer.

### Context metadata API correction (Actions passed, device retest pending)

App-only `ContextMetadata.hpp` issues EGL client-type/config-ID queries and GL
major/minor/profile queries after make-current. Every actual result/error is
logged, query failures still block, and no returned version/profile value is
used as a desktop capability gate. The pinned candidate's `gl/getter.cpp`
returns granted-request bookkeeping for desktop major/minor and a fixed Core
profile bit. The report explicitly labels these as metadata, not tested semantics.
No candidate, ANGLE, recipe, version string or cap changes are needed.

CI compiles the actual App query plan with ASan/UBSan: exact API/token sequence,
unmodified returned values and error propagation at each query. A Python source
guard prevents reintroduction of the invalid EGL queries; this remains policy
testing, not device execution. Existing GPU clear, three shared/migrated content
reads, exclusive owner-thread handoff and cleanup remain required and unchanged.

For the next fresh-process report, expect `context_metadata_correct_api` followed
by `shared_gpu_content_and_migration`. Context creation is now evidenced, but
content sharing/migration and B1.1 overall remain pending. No B1.2/guest GL or
performance claim follows from the metadata correction.

Reproducible correction delivery:

- Branch `experiment/b11-mobileglues-probe`, code `d95d32be3d003f3c2c6c5a84b2f87132e4f6c7b2`.
- [iOS Actions 40816895275](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816895275) **passed**. The exact candidate framework cache was reused, then architecture/export/link checks, independent App compilation and IPA bundle-isolation/hash checks passed. All compilation was in Actions; no server build or deployment change.
- [Self-signable IPA 12872158793](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816895275/artifacts/12872158793), [diagnostics/LGPL corresponding source 12872457982](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816895275/artifacts/12872457982).
- [CI 40816895381](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40816895381) **passed**: actual query-plan and provider-policy C++ ASan/UBSan tests, 9 B1 source/isolation tests, 32 Swift tests, existing native vtest/two-slot ownership, Linux proxy and Mesa patch gates. No device metadata values or GPU results are inferred from fixtures.
- IPA SHA256 `953fae77ece0a7c88378b0cc80c7f8ea9cba230b303a6685cce19e7d34096d8f`; downloaded ZIP integrity, published checksum and embedded source/run verified.
- Candidate framework still `63f17c59ff480b7cd71463f901f28f76611a3a40bba6e9d9dbd37d63d8f1b6c0`, same as the device report at `8c5a943`. ANGLE EGL/GLESv2 hashes and all dependency pins/recipes are unchanged.
- Changed: `App/Probe.mm`, new `App/ContextMetadata.hpp`, actual query-plan C++ test, Python guard and CI wiring; concise docs/device evidence synced. No candidate or formal renderer implementation changes.

Update only standalone **RemoteGPU B1.1**, force-close/relaunch, run once, then
share Full Report including any later BLOCKED result. No server restart/pairing
is needed. Overall B1.1 acceptance awaits actual shared-content/migration results;
B1.2 shader semantics and B1.3/guest GL remain untested. No new performance data.
