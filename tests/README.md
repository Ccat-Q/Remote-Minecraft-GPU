# Capability gate

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
