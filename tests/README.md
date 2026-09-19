# Capability gate

`gl-capability` is compiled exclusively by the `Build Linux PoC` GitHub Actions
workflow. Download and extract its `linux-poc-<commit>` artifact to the Ubuntu
compute client; do not compile it there. Run it through the supplied launcher:

```sh
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=virpipe ./bin/run-gl-capability
```

Run it only after the RemoteGPU proxy and iPhone renderer are connected. A
failure is a stop condition for Minecraft work, not something to bypass with a
compatibility-profile context.
