# Capability gate

## A1 low-capability dynamic gate

`tests/gl_remote_present.c` requests OpenGL 2.1 (legacy compatibility) and GLSL
120, uploads a real VBO and changes position/color uniforms before every real
swap. Actions builds `gl-remote-present`; options are `--frames`, `--fps`, and
`--hold-seconds` (minimum 0.5). The final hold keeps the window/resources/session
alive without further swaps. No version override or client pixel readback.

`python3 tests/mesa_present_gate.py _stage --dynamic` runs the real
virpipe -> proxy -> QUIC -> Linux receiver -> native decoder/renderer path.
An explicit CI-only `-verify-present-socket` forwards the consumed vtest byte
boundary and PRESENT to the native host. The receiver waits for the oracle
ACK before forwarding later writes; this is test-side serialization, not the
production PRESENT design. Native code pins the actual resource, waits for its
fence, reads it **locally at the renderer**, and compares thousands of pixels
against a CPU triangle reference (edge tolerance, format/origin normalization).
The normal vtest/QUIC path must contain **zero TRANSFER_GET**. Test-side resource
reads are counted separately and never travel back through the proxy.

The oracle checks every application frame in order, tolerates at most one
initialization PRESENT before frame 0, and rereads the final resource during
the producer's live hold without new packets. Different frame counts/rates
and deliberately corrupted-color/repeated-frame fixtures exercise the oracle;
negative controls must fail specifically on pixels, not merely transport loss.
Existing Core/GLSL 150, explicit application glReadPixels and resource-lifetime
tests remain separate regressions. A1 Linux software-renderer PASS is not
iPhone GPU or remote iPhone display acceptance; A2 is still pending.

## Existing Core capability gate

`gl-capability` is compiled exclusively by the `Build Linux PoC` GitHub Actions
workflow. Download and extract its `linux-poc-<commit>` artifact to the Ubuntu
compute client; do not compile it there. Run it through the supplied launcher:

```sh
GALLIUM_DRIVER=virpipe REMOTEGPU_VTEST_LEGACY=1 ./bin/run-gl-capability
```

Run it only after the RemoteGPU proxy and iPhone renderer are connected. A
failure is a stop condition for Minecraft work, not something to bypass with a
compatibility-profile context.

`gl-present` and `mesa_present_gate.py` verify the opt-in Mesa frontbuffer hook
in GitHub Actions. This gate starts a fresh renderer/proxy/diagnostic receiver
for each case, checks at least three consecutive ordered frame markers and zero TRANSFER_GET for
presentation, then repeats with an explicit application glReadPixels request.
The red-pixel result verifies rendering and readback compatibility. This is
not a display test: the Linux endpoint logs PRESENT without presenting it.
The demo uses GLSL 1.50 shaders, a Core-profile VAO and three triangle draws;
the explicit readback samples the rendered triangle's center, not a clear color.
The harness applies virpipe environment variables only to the demo, after
`xvfb-run` starts its local software X server; applying them to Xvfb itself
would make the compositor consume the remote renderer session.
An initialization frontbuffer flush can emit an additional marker before the
three swaps; frame IDs count presentation events rather than application swaps.
