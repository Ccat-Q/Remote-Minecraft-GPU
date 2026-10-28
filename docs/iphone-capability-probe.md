# Ubuntu -> iPhone capability probe

## Status and independent routes (2026-10-28)

Separate route A single-frame remote display is now device-accepted at
`3b5e80d` (Ubuntu GL 2.1/GLSL 120, real VirGL draw, GET=0). That result does
NOT pass the GL 3.2 Core/GLSL 150 capability gate described here. Use
[Connect Remote Display](a21-remote-present.md), not this capability-only mode,
for remote draws. The [7/12-frame device batch](evidence/a21-multiframe-2026-10-28/README.md)
has passed visual/120-second hold/cleanup acceptance; full same-process
render reconnect is deferred. [A3.1](a31-async-single-slot.md) is a separate,
opt-in single-slot asynchronous implementation, still device-pending.

The network capability endpoint is **implemented and CI-built, not accepted
end-to-end on device**. User reports separately confirm local IOSurface/Metal
display with corrected orientation and native context/caps initialization.
These tests do not execute Ubuntu-originated draws.

Known failed prerequisite: iPhone 17 / iOS 27.0.1 rejects GLES 3.1/3.2; GLES
3.0 works, and both capsets report guest GLSL 130 rather than 150. This blocks
the current Minecraft capability combination, not remote GPU feasibility.
Actual Ubuntu guest Core-context creation remains a separate runtime gate.

The [next-stage plan](next-stage-plan.md) defines independent routes:

- **A — Remote PRESENT:** a new low-capability changing demo, current renderer
  and the existing synchronous resource/snapshot/display adapter; no initial GL 3.2 requirement.
- **B — Graphics capability:** isolated candidate probes, then executable
  Ubuntu guest GL 3.2 Core/GLSL 150 before Minecraft. No candidate is accepted
  merely because it links or advertises a version.

The commands below are reference instructions for the existing
**capability-only** mode. This development round does not modify DNS, TLS,
firewall or production deployment.

This diagnostic executes native protocol-0 vtest commands on the iPhone, but
does not present remote frames. It rejects every PRESENT envelope and all
TRANSFER_GET requests. This intentionally prevents display readback to Ubuntu;
the production renderer must later allow genuine application readback while
keeping the presentation path GPU-only. A rejected readback is a diagnostic
configuration error, not proof of missing GL support.

The user-provided target is `gpu.opencat.cc.cd`, Ubuntu public IP
`160.202.237.166`. Verify DNS and certificates before running; do not infer
reachability from these values alone.

## DNS and TLS

Use a dedicated DNS-only (gray-cloud) A record pointing to the Ubuntu IP.
Do not change other website records or disable proxying for the entire zone.
An AAAA record is appropriate only if that IPv6 address and UDP port actually
work. DNS-only exposes the origin IP; Cloudflare CDN/WAF does not protect this
connection. Protect the experimental service with a strong private pairing
token and do not give untrusted clients access to the renderer.

Normal Cloudflare HTTP/HTTPS proxying is not a transparent tunnel for the
`remotegpu/1` QUIC ALPN. Custom UDP proxying is a separate
[Spectrum service](https://developers.cloudflare.com/spectrum/).
Direct connections need a publicly trusted certificate (or an explicitly
trusted private CA), including its full chain, matching the hostname.
[Cloudflare Origin CA certificates](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/troubleshooting/)
are not automatically trusted by direct clients. No trust-all bypass is
implemented. Never send private keys or Cloudflare API tokens in chat.

## Run downloaded Linux artifacts (no local compilation)

Download a verified **Build Linux PoC** artifact and extract its `bin/` and
`mesa/` directories together. Artifact extraction may require restoring
executable permissions. Runtime dependencies include Xvfb/xauth, GLFW, GLEW
and the system GLX software backend; install distribution binaries if missing.
The X server must not inherit the Mesa virpipe environment.

In terminal 1, set a fresh strong `REMOTEGPU_PAIRING_TOKEN` privately and start:

```sh
./bin/remotegpu-proxy \
  -unix /tmp/.virgl_test -listen :4433 \
  -cert /path/to/fullchain.pem -key /path/to/privkey.pem \
  -pairing-token "$REMOTEGPU_PAIRING_TOKEN"
```

Permit inbound UDP 4433 only under the operator's chosen firewall policy.
Certificate issuance/DNS/firewall changes require operator configuration; the
repository does not silently modify them. The server needs no local GPU or
virgl_test_server: rendering is performed by the phone endpoint.

Install the Actions-built unsigned IPA after external signing. Tap
**Connect Capability Probe**, enter `gpu.opencat.cc.cd`, port `4433` and the
same token. Wait for **QUIC ready**, then in terminal 2 run:

```sh
env -u REMOTEGPU_PRESENT_SOCKET xvfb-run --auto-servernum env \
  GALLIUM_DRIVER=virpipe REMOTEGPU_VTEST_LEGACY=1 \
  VTEST_SOCKET_NAME=/tmp/.virgl_test ./bin/run-gl-capability
```

The probe creates a hidden OpenGL 3.2 Core window without rendering/swapping.
Do not run glxgears or Minecraft in this mode. Unexpected presentation or
readback causes explicit closure, not fallback CPU/framebuffer streaming.

Save the Ubuntu stdout/stderr and exit code plus the iPhone **Share Report**
output. Guest GL_VERSION/GLSL_VERSION/profile and feature verdict come from
Ubuntu's Mesa probe, not from the phone's host GLES version or a successful
handshake. GLSL 130 already fails the planned shader-level prerequisite;
save the actual Ubuntu context result separately. An unrun Core-context test
is neither PASS nor a measured failure. Minecraft remains blocked; route A
can proceed within current capabilities.

`tests/gl_capability.c` also currently requires timer query. Its planned fix
separates baseline GL 3.2, optional diagnostics and Mod-specific requirements.
Until that code change passes Actions, record this as the **existing stricter
gate**, including the exact stage that failed. It is not fixed by these docs.

## Ownership

Network.framework callbacks enqueue ordered tasks onto one serial renderer
queue. That queue can migrate OS threads: the native endpoint restores the
last EGL context on entry and unbinds it on every exit, including errors.
Renderer callbacks track that context, and destruction restores it before
releasing session resources. Concurrent diagnostics/reconnects are disabled
until native teardown completes. Counters/sequence numbers advance only after
native submit succeeds; already queued messages are ignored after closure.

This capability-only endpoint verifies transport/capabilities only. The separate
remote-display endpoint now has accepted synchronous snapshots and an opt-in,
device-pending A3.1 timer-driven scheduler; capability mode still rejects PRESENT.

The local **VirGL Context + Caps** diagnostic also tries GLES 3.2, 3.1 and 3.0
before virgl initialization and reports the actual versions. Rejected contexts
or unexpected downgrades distinguish backend support from renderer selection;
they do not change the production feature level or pass the guest Core gate.
The fixed orientation shader is compiled into `default.metallib` by Actions,
and packaging verifies that the library is present. User screenshots now
confirm the upward orientation; CI alone cannot assert final pixel orientation.
Repetition, leak/thermal tests and sustained remote display remain unaccepted.

## Separate acceptance records

Save build/source SHA, dependency revisions, device/OS, guest context/GLSL,
actual shader/test results and unsupported features. Distinguish:

1. Local GLES/IOSurface triangle and native vtest initialization/caps.
2. Capability-only QUIC traffic and Ubuntu context creation.
3. Route A real remote draw/snapshot/completion-driven display.
4. Route B candidate feature execution and final guest Core context.

Do **not** send a swapping demo to **Connect Capability Probe** for route A:
the current mode correctly rejects PRESENT. The existing remote-display mode must
retain the source until GPU copying completes and snapshots until Metal
completes, without depending on another incoming packet to drive completion.
No normal-display demo should call glReadPixels or fall back to full-frame CPU
readback. Preserve a separate explicit application-readback test.

Existing counters show bytes/sequences, not FPS/GPU-wait/RTT. Those metrics,
full performance attribution remain future work. Bounded command admission,
proxy phase timeouts/cancellation/keepalive and local completion/quiet-hold
records are implemented for A2.1-Final, not yet multi-frame device acceptance.
Historical CI/source records remain in
[architecture.md](architecture.md#retained-ci-and-source-evidence).
