# A3.3 first slice: safe retirement and ownership isolation

Date: 2026-11-10. Status: **IMPLEMENTED / CI_PASS; device gates NOT_RUN**.

Implementation: `40392d377700bad9cbca8ecb176558d1f53e6a36`, branch
`feature/reverse-vtest-hardening` (not merged to main).

- [CI / Swift fault models and regressions](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/42843557128): success.
- [Linux native rendering gate](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/42843557366): success.
- [Unsigned iPhone full build](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/42843557141): success.
- IPA artifact ID `13777072794`, name `ios-interop-prototype-40392d377700bad9cbca8ecb176558d1f53e6a36`,
  archive digest `sha256:22ef339d97ebc501cba8d372b5a0221702c03facdf4dc8fd02cf03f2c4724e32`.
  This is the GitHub artifact archive digest, **not the inner IPA hash**.
- Diagnostics artifact ID `13775179940`. Both artifacts were unexpired when checked.

All builds/tests above ran only in GitHub Actions. No new real-device acceptance
is inferred. The installed App must be matched to this source before device retesting.
This is not continuous rendering, a backend migration, or a new A3.2 device pass.
Existing finite-frame and 64×64 admission limits remain unchanged.

## Approved scope

Introduce safe Remote session ownership, cancellation/retirement/quarantine state,
generation-filtered UI and fault-model tests. Preserve legacy diagnostics in a
separate process mode, explicitly selected by the user; switching requires fully
terminating and reopening the App. Default is safe Remote. Saving the preference
does not change the current process or release a quarantined owner.

## Ownership and state

[SessionRetirement.swift](../ios/RemoteGPU/SessionRetirement.swift) provides the
process-wide safe Remote owner. A UUID identifies each admitted generation;
monotonic snapshot revisions prevent stale UI state from reviving an old session.
The phases are running, stopRequested, retiring, quarantined and retired.
Only confirmed native cleanup may retire the generation and admit a replacement.
Repeated stop/network terminal events share an independent one-shot finish gate,
so a blocked renderer queue cannot accumulate one finish job per stop request.

[NativeRemoteDisplayConnection.swift](../ios/App/NativeRemoteDisplayConnection.swift)
acquires before initialization, roots its native owner, immediately requests atomic
cancellation and closes the transport handoff on stop. A separate Dispatch watchdog
requests quarantine after five seconds; it never calls GL, touches native resource
state, or releases ownership. This is not a hard realtime deadline: App suspension,
scheduling and driver hangs can delay work. Native cleanup stays on its original
serial owner queue.

[Prototype UI](../ios/App/RemoteGPUPrototype.swift) requires matching session/token
and current revision. Stop/retiring/quarantine makes the retained image non-live
and restores the idle timer, without unlocking native entry points. A finished
report alone cannot unlock: retired state and the shared owner gate must agree.
An admission rejection with no native token is not cleanup of another owner.

## Explicit native outcome

[The endpoint](../ios/Renderer/RGPURemoteDisplayEndpoint.mm) exposes
`cleanupSucceeded`, initially false. Synchronous PRESENT copy/pin state is now
endpoint-owned rather than a fallible stack-owned cleanup path. Before attempting
cleanup the endpoint roots itself; failure retains remaining dependent state,
rejects retry and requires process restart. Initialization failure likewise roots
the uncertain native endpoint and causes Swift quarantine.

SingleFrameCopy checks Metal before any GL/context/target destruction. Pending or
error status is not cleanup success; make-current failure cannot proceed to destroy.
Buffered cleanup propagates the first failure without resetting that failed slot.
ANGLEHost uses explicit checked cleanup; only observed success permits reset.

**Important distinctions:**

- A watchdog timeout can be followed by a genuine late successful native return;
  that same generation may then retire. The watchdog itself never certifies cleanup.
- A native close attempt samples Metal status once. Pending/error causes explicit
  cleanup failure and **permanent quarantine**, even if Metal finishes later.
  There is no automatic polling/retry/unquarantine of this failure. Restart is required.
- `glFinish` and other driver cleanup calls may block indefinitely. This slice bounds
  scheduling/state admission, not the driver's execution or total resource reclamation.
- session destruction and virgl cleanup remain void, non-rollback APIs. Later failure
  retains the remaining host, not the already destroyed session or a full transaction
  rollback. Checked success means observed API results, not leak-free driver certification.
- Legacy local diagnostics retain their older best-effort stack destructors. They are
  preserved only in legacy process mode and have **no A3.3 retirement guarantee**.
  This slice does not certify arbitrary multi-controller legacy usage or external
  callers bypassing the App's mode/owner entry points.

## Verification matrix

[SessionRetirementTests.swift](../ios/Tests/SessionRetirementTests.swift) contains
pure Foundation fault models for exclusive acquire, UUID/revision filtering,
repeated cancellation, watchdog quarantine, late success, irreversible cleanup
failure, blocked owner queue and concurrent one-shot finish admission.
These are real production state/gate tests, not native GL/Metal fault execution.

All compilation and tests must run in GitHub Actions only. Required gates:

1. Existing CI: Swift 6 package build/tests and iPhone source typecheck, Go and
   native protocol/lifetime contract regressions.
2. Unsigned iPhone App: full ObjC++/Metal/Swift build using the verified retained
   renderer sysroot; source SHA, run and provenance must match.
3. Actual iPhone: repeat existing A3.2 normal/saturated cases; stop at producer,
   copy and Metal phases; background/disconnect; duplicate stop; verify immediate
   non-live UI, no premature reconnect, clean-retired reconnect, and restart-only
   quarantine. Preserve complete reports and installed unsigned source provenance.
4. Driver-hang model: watchdog must report isolation without native cleanup success;
   it cannot establish that a real hung GPU will recover or that resources were freed.

The initial document recorded unexecuted verification gates. After explicit user
approval, this slice was committed and pushed and the Actions receipts above were
verified. No local compilation/tests, main merge or deployment occurred. Existing
device evidence was not overwritten; real-device A3.3 acceptance remains pending.
