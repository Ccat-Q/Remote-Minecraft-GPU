# B1.1 device acceptance: provider/context/content sharing only

User-supplied real device report, iPhone18,3 / iOS 27.0.1 (24A446).
This is a report summary, not a reconstructed raw log or simulated result.
Source `d95d32be3d003f3c2c6c5a84b2f87132e4f6c7b2`, Actions `40816895275`.
[Full build provenance](provenance.json) matches the installed build reported
by the user; framework hashes describe unsigned artifacts before self-signing.

Device-executed evidence:

- Four expected bundled frontend/backend providers; bootstrap result 0 and 384
  backend entries. All seven frontend direct/proc identities matched.
- Platform route 2: checked ANGLE proc-table entry owned by bundled GLESv2.
- Display/config/pbuffer/root and shared-context creation, root make-current,
  EGL client/config and GL metadata queries all succeeded.
- Root GPU clear completed with GL 0. Shared-context FBO content was read back.
- Owner unbound, worker bound the same root exclusively, verified GPU content,
  unbound/released; original owner rebound and verified the content again.
- All three FBO statuses were 0x8cd5 (complete). Actual RGBA was
  `51,153,229,255` each time versus expected `51,153,230,255`: within the
  pre-existing per-channel +/-1 tolerance, not a post-hoc tolerance change.
- Texture deletion, unbind, shared/root destruction, pbuffer destruction,
  terminate and thread release all reported success; GL 0 / EGL 0x3000.
- Device verdict: `PASS: B1.1 provider/context/content-sharing checks ONLY.`

Accepted scope: isolated provider/context/content-sharing and exclusive
thread migration/return checks on this device/build. This is not driver-leak
profiling, GL 3.2 conformance, GLSL 150 compilation, VirGL/guest integration,
remote display or sustained performance acceptance. Three 1x1 local diagnostic
reads are test oracles, not framebuffer streaming.

Frontend 4.0/GLSL4.00 strings and 3.2/Core metadata are not capability proof;
the pinned getters use request bookkeeping/fixed profile bits. Actual backend
remains ANGLE Metal GLES3.0 / GLSL ES3.00. B1.2 actual shaders/features and
B1.3 actual Ubuntu guest gates remain untested.
