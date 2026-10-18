# A2.1 bounded remote-display diagnostic

Source baseline: device-accepted A2.0
`98e65d1878ea132dbf4cb169e521facdc62f04a6`; independent branch
`feature/a21-remote-present`. **A2.1 iPhone network display is not yet accepted.**
No new renderer, Mesa patch, PRESENT wire layout, ACK, DNS or deployment change.

## Implementation and limits

- **Connect Remote Display** is separate from **Connect Capability Probe**.
  Capability mode still rejects PRESENT and all TRANSFER_GET. Display mode
  uses the same native decoder with TRANSFER_GET disabled and never generates
  a local pattern. Ubuntu's unchanged A1 `gl_remote_present.c` is the producer.
- `QUICRenderConnection` optionally admits one decoded batch, then stops issuing
  NWConnection receives until its local consumer completes. Budget: 4096
  envelopes and 16 MiB + 64 KiB decoded bytes; incomplete vtest command budget
  remains 16 MiB in native code. Network.framework also has its own finite QUIC
  buffers. Outstanding send/reply bytes are capped at 2 MiB. This is receive
  backpressure, **not** a network frame ACK.
- `RemoteGPUSerialDisplayOrder` requires zero envelope flags, consecutive vtest
  sequence and PRESENT frame IDs starting at 1, and **afterSequence exactly
  equal** to the sequence processed at this single-stream slot. Native code
  additionally requires a complete vtest command boundary and a live resource.
  No future PRESENT is queued waiting for later commands; at most one snapshot
  exists. Reject unsupported data and close, never drop GPU state commands.
- `VTestSession` records actual legacy resource descriptors and command counts.
  A1's CI window is format 1 (BGRA8), 64x64, flags=0, target=2 (2D), samples=0,
  array=1, last_level=0. These facts are printed again in the current A1 gate.
  Remote endpoint initially accepts 64x64 full-resource PRESENTs, level/layer=0,
  samples 0/1, ordinary 2D color formats 1 or 67 only. Format 2/BGRX, nonzero
  origin flags, partial regions, arrays, mips and multisampling fail explicitly.
- `RGPUFrameCopy.hpp` extracts A2.0's real shared-context GPU blit. It checks
  creation metadata against Resource Info, flags, GL texture visibility,
  normalized linear 8-bit RGBA attachment components and complete FBOs. Ordinary
  VirGL BGRA8 GL storage is copied as logical RGBA, with **no guessed manual
  channel swap**. A1 window raw GL rows are top-left (as the independent A1
  oracle demonstrates), unlike A2.0's raw-GL fixture coordinates. Explicitly
  invert source Y in the GPU blit for the window, then reuse the accepted
  IOSurface/Metal orientation shader unchanged. flags=0 alone must not be used
  to infer which producer coordinate convention was used. BGRA8 on iPhone needs its own
  A2.1 screenshot; Linux success is not that evidence.
- At PRESENT, native code pins the source and captures a dedicated fence.
  It independently polls producer completion, takes the GPU snapshot, waits
  for copy completion, releases the pin and displays via Metal. Only then can
  subsequent vtest in the batch execute. No later packet is needed to complete
  the last frame. Producer/copy/Metal completion waits have 10-second deadlines
  and cancellation checks. A Metal completion block independently holds the
  IOSurface backing store on cancellation/timeout, until actual GPU consumption;
  endpoint cleanup never pretends that pending GPU resources were already freed.
  Exceptional GL cleanup still uses conservative local glFinish; no hard
  real-time guarantee is possible if driver API calls themselves hang. These
  waits/leases are NOT the A3 asynchronous frame scheduler.
- Maximum 16 PRESENTs per session (covers 12 application frames plus a possible
  startup PRESENT). Reports retain at most 512 chunks / 256 KiB; UI updates
  occur on display/terminal events, not every vtest command. No unbounded GPU
  ingress or pending display queue is introduced.
- User cancellation atomically interrupts producer/copy/native busy-wait loops.
  The serialized owner releases pins, surfaces, contexts and session resources.
  Peer EOF/error also cleans up. Last-frame **live session hold** must be
  observed before disconnect; no reconnect/recovery acceptance is implied.

## CI evidence boundaries

Preserve the A1 dynamic oracle, explicit application glReadPixels/Core/GLSL 150,
native lifecycle tests and A2.0 pattern oracle. Add strict order / stale-future
sequence / invalid resource / snapshot admission / bounded batches / cancellation
tests. `a21_shared_copy.cpp` uses real Linux EGL sharing and GPU blit for formats
67 and 1, overwrites/unrefs the source after copying, and checks every snapshot
pixel using **test-only** readback. It does not exercise IOSurface or iPhone GPU.
The extra `--shared-scanout` gate runs the real A1 Ubuntu OpenGL app through
QUIC/native decoder, then an EGL-shared GPU snapshot using the same window-row
normalization, and checks the displayed orientation/colors/frames/hold against
the independent A1 oracle. The old direct-transfer oracle also remains intact.
No readback is added to the phone's display implementation.

All builds in Actions. Native gate reuses exact dependency run `38186021966`;
iOS build explicitly selects sysroot run `38206257487`. Each new IPA contains
actual app/A1/A2.0 SHAs, dependency pins, sysroot source/run and unsigned framework
hashes. Actions publishes source-tagged `a21-tools-*` (demo, proxy, wrapper),
renderer/regression logs, unsigned IPA and its build provenance.

## Device procedure

1. Sign the new source-tagged IPA and embedded frameworks. Use **Connect Remote
   Display**, not Render Probe, A2.0 or Capability Probe. It displays A1's square
   64x64 target without stretching it into the old 16:9 diagnostic region.
2. Use a **separate diagnostic proxy**, socket paths and unused UDP port. Do not
   stop or reconfigure production services. Use an existing trusted certificate
   for the hostname; do not disable certificate validation or modify DNS.
3. Download `a21-tools-<app SHA>` and the explicitly verified Linux PoC dependency
   bundle from run `38186021966`. Artifact transport strips execute permissions:
   `chmod +x a21-tools/bin/*`. Set absolute paths in the example below. Ubuntu
   needs runtime `libglfw3`, `libglew`, Xvfb and xauth, not a compiler.

```sh
# Terminal 1: isolated diagnostic listener; reuse existing certificate FILES.
case_dir=$(mktemp -d /tmp/rgpu-a21.XXXXXX)
export VTEST_SOCKET_NAME="$case_dir/vtest.sock"
export REMOTEGPU_PRESENT_SOCKET="$case_dir/present.sock"
./a21-tools/bin/remotegpu-proxy -listen :4434 \
  -unix "$VTEST_SOCKET_NAME" -present-socket "$REMOTEGPU_PRESENT_SOCKET" \
  -cert "$RGPU_TEST_CERT" -key "$RGPU_TEST_KEY" -pairing-token "$RGPU_TEST_TOKEN" \
  2>&1 | tee "$case_dir/proxy.log"

# iPhone: trusted hostname, port 4434, matching token. Wait for QUIC ready.
# Terminal 2: set these to exactly the same test paths; do not use defaults.
export RGPU_MESA_ROOT=/absolute/path/to/verified-linux-bundle/mesa
export VTEST_SOCKET_NAME=/tmp/rgpu-a21.REPLACE/vtest.sock
export REMOTEGPU_PRESENT_SOCKET=/tmp/rgpu-a21.REPLACE/present.sock
sh ./a21-tools/run-gl-remote-present.sh --frames 1 --fps 1 --hold-seconds 120 \
  2>&1 | tee /tmp/rgpu-a21-one-frame.log
```

If the chosen diagnostic UDP port is not reachable, report the network failure;
this code change does not grant permission to alter firewall/production rules.

4. Record Ubuntu `DRAW frame=...` (zero-based), position/color and `HOLD_BEGIN`. A
   possible startup PRESENT precedes application frame 0, so PRESENT IDs need
   not equal application frame IDs. Expect a small upward triangle toward the
   lower-left for frame 0: RGB 40/50/60, offset (-0.32,-0.12), dark RGB 8/16/24.
   Share full phone report and screenshot DURING the 120-second hold. It must
   show actual vtest/PRESENT sequences, live resource metadata, producer/copy
   completion, Metal displayed frame, counts including TRANSFER_GET=0, and no
   local fixture evidence substituted for Ubuntu's frame.
5. Confirm the last image remains visible after traffic stops while the session
   is still open. Then press **Disconnect Remote Display**, including once
   during GPU work if practical. Share cleanup/error logs; rerun A2.0 and caps
   to catch stale global EGL/renderer ownership. Crash recovery is not tested.
6. **Only after one-frame visual acceptance**, start fresh sessions for
   `--frames 7 --fps 1 --hold-seconds 120`, then 12 frames. Compare Ubuntu frame
   colors/positions with phone snapshots/reports; no frame-state command loss,
   ordering errors, unexpected stalls or full-frame CPU fallback is acceptable.
   These finite synchronous diagnostics do not establish A3 throughput/FPS.
