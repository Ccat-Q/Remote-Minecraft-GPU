# Ubuntu -> iPhone capability probe

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
handshake. The reported guest GLSL 130 suggests the 3.2 Core gate may fail;
record that failure honestly and investigate capabilities before Minecraft.

## Ownership

Network.framework callbacks enqueue ordered tasks onto one serial renderer
queue. That queue can migrate OS threads: the native endpoint restores the
last EGL context on entry and unbinds it on every exit, including errors.
Renderer callbacks track that context, and destruction restores it before
releasing session resources. Concurrent diagnostics/reconnects are disabled
until native teardown completes. Counters/sequence numbers advance only after
native submit succeeds; already queued messages are ignored after closure.

This verifies transport/capabilities only. Ordered GPU snapshot at PRESENT,
independent fence completion and Metal display scheduling remain future work.
