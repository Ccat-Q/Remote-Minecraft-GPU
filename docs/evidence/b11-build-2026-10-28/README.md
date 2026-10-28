# B1.1 isolated iOS Probe build evidence, 2026-10-28

Verdict: **iOS ARM64 compilation, link/export/isolation checks, IPA packaging,
unsigned bundled-binary hash verification and retained CI regressions passed**.
Device runtime remains **PENDING**. No iPhone initialization, sharing,
thread-migration, GLSL 150, VirGL integration or guest GL 3.2 success is inferred.

## Reproducible delivery

- Branch: `experiment/b11-mobileglues-probe`.
- Actual app/code SHA: `ff4fae65b068409964fc5b45d688b7abe95a23ee`.
- Accepted route A base: `6dd8b04c049da999b9dbd91e4c341f4a8b6d5e31`, followed by its user-confirmed A3.2 evidence record. Formal `ios/Renderer`, protocol and deployment code are unchanged.
- [Successful IPA build 40783974009](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40783974009).
- [Self-signable IPA artifact 12856659884](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40783974009/artifacts/12856659884).
- [Diagnostics and modified LGPL corresponding source 12858535784](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40783974009/artifacts/12858535784).
- IPA file: `MobileGluesCompatibilityProbe-unsigned.ipa`; SHA256 `2bef2c720e211315bb39d099d0302b9de62ca9a98133061aab06015f865e31e0`.
- Embedded provenance source/run checked against the downloaded IPA; ZIP integrity passed. Resigning may change bytes; hashes here precede external signing.
- Xcode 16.4 (16F6), iPhoneOS SDK 18.5, iOS deployment target 17.0, arm64, CMake 4.4.3. This SDK is a build input, not a claim of execution on any device OS.

## Pinned providers/dependencies

MobileGlues `97558a69157b033b890958b1e49258c5b51a80c6`.
Shader/hash dependencies are its exact gitlinks:

| Dependency | Commit |
| --- | --- |
| glslang | `f5f664dee8146676b04a332a7233959fc3ce9681` |
| SPIRV-Cross | `a0fba56c34a6700f1724bf9b751da5b488a3775c` |
| xxhash | `c2866db364b6ea3a11933e62235ddc166ba18565` |
| ska/flat_hash_map | `21c1cec95abee1beef827e4a7c95f692875d9594` |

ANGLE is reused without rebuilding from verified sysroot run `40636888480`,
recipe source `61abde5f505165ff7200b2600a6cbaf7ea2f426c`, UTM
`9d00a54833184628c696bcbfafbf344cea566e59`, WebKit/ANGLE source
`ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10`.
`B11Provenance.json` includes original sysroot provenance, checked adaptation
hashes and corresponding source pins. Only these three frameworks are embedded:

| Actual unsigned bundled binary | SHA256 |
| --- | --- |
| MobileGluesProbe | `47fafd8b923cefd1c8c28e11b580ba01a8f2b716e5877d8c8f2e14d178399f2c` |
| EGL | `02bebdf880327ba344c3ffc46705865b47406db263f8c5c14f35104dc1514756` |
| GLESv2 | `699a87ecf2b9ae19c2b027a2d13cd5ae2bf79e124f7bd42c45ced71e8d6be2be` |

The candidate's Mach-O dependencies are only libc++ and libSystem. The app
links UIKit/Foundation/CoreFoundation, libobjc/libc++/libSystem, but no GL/EGL
framework: it opens the three exact bundled providers through explicit handles.
No virglrenderer/epoxy is embedded. Static dependency inspection does **not**
prove runtime provider ownership; the device must execute the dladdr checks.

The diagnostics artifact preserves exports, actual linkage, toolchain,
bundled hashes, app build log, recipe and source diff, overlays, licenses and
the complete modified candidate/dependency sources needed by the CMake recipe.
The successful final build used the verified candidate framework cache and
skipped candidate recompilation; Mesa/ANGLE were not rebuilt.

## Actual tests and failures

- [CI 40783973931](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40783973931): seven B1.1 adaptation/isolation/provenance contract tests, 32 Swift tests, native decoder and real slot-engine sanitizer tests, plus retained Go/Mesa/policy checks passed. Contract fixtures are not device execution.
- [Native Render Gate 40784285850](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40784285850), same final code SHA: retained real Linux A1/A2/A3.2 drawing, separate legal application readback, shared snapshots and lifetime tests passed. Linux software-renderer results are not new iPhone results.
- [Initial 40722405658](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40722405658): runner allocation failed; no source compilation ran. Switched the independent workflow to macOS 15.
- [40782294117](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40782294117): duplicate error-policy anchor rejected by the checked recipe. Fixed by matching Apple-specific context and testing that Android is not changed.
- [40782522761](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40782522761): `gl/framebuffer.cpp:350..354`, `aliases are not supported on darwin`; three same-signature forwarding exports fix this without changing capabilities.
- [40782851679](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40782851679): `egl/trace.h:38`, undeclared `__NR_gettid`; isolated recipe uses the Apple pthread thread-ID API.
- [40783125274](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40783125274) and [40783483288](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40783483288): candidate compile/link passed, App header path and actual shipped `gl32.h` declaration header were corrected. No ES3.2 context request or version override was added.
- [40783774988](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40783774988): app source compiled, but UIKit symbols were undefined; explicit UIKit/Foundation SDK dependencies fixed linking. GL providers remain dynamically selected, not linked by order.

## Next device gate

Install the standalone **RemoteGPU B1.1** app alongside RemoteGPU, tap
**Run Provider + Context Probe**, then **Share Full Report**. No Ubuntu service
or pairing token is used. One attempt per process; relaunch the Probe to repeat.
Require actual four provider identities, proc ownership, explicit bootstrap,
context creation/shared-content checks, unbind/worker migration/return and
cleanup results. A BLOCKED result or crash log is evidence to debug, not a
reason to claim MobileGlues globally impossible or silently use another provider.

Frontend GL/GLSL/profile metadata is explicitly unverified. Three planned 1x1
offscreen readbacks are local content oracles, not a display/transport path.
No FPS or GPU timing claim is made. B1.2 actual shader/desktop-feature tests,
B1.3 isolated VirGL integration and the real Ubuntu guest gate remain unpassed.
