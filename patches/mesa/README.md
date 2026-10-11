# Mesa vtest presentation patch contract

Apply `0001-remotegpu-force-legacy-vtest.patch` only to the pinned Mesa source
after the local vtest trace has selected the no-FD profile. It changes protocol
negotiation only. Apply `0002-remotegpu-present.patch` next. It targets
`src/gallium/winsys/virgl/vtest/virgl_vtest_winsys.c`, specifically
`virgl_vtest_flush_frontbuffer()`.

The presentation patch replaces only the presentation-only call path:

```text
TRANSFER_GET -> busy wait -> displaytarget CPU copy -> displaytarget_display
```

with a Unix datagram sent to `REMOTEGPU_PRESENT_SOCKET`:

```c
/* Field description only: encode explicitly, never send this padded struct. */
struct rgpu_present_signal {
    char magic[4];       /* RGPF */
    uint64_t byte_offset;/* bytes written on vtest client->renderer stream */
    uint64_t frame_id;
    uint64_t resource_id;
    uint32_t level, layer, x, y, width, height;
};
```

`byte_offset` is mandatory. It must be maintained by the vtest socket write helper
and lets the proxy delay `PRESENT` until all preceding raw vtest bytes have
been framed. Do not hook GLFW. Do not suppress `TRANSFER_GET` requested by an
application resource map/readback.

The wire signal is exactly 52 bytes, little-endian, without struct padding.
Mesa autobinds a Linux Unix datagram return address and waits for a 12-byte
`RGPA` + little-endian `frame_id` acknowledgement. The proxy acknowledges only
after it has queued the marker on the ordered QUIC stream. This is a local
barrier: it does not wait for the phone or GPU. It prevents subsequent
`RESOURCE_UNREF` from overtaking the independent presentation datagram. Missing
or malformed acknowledgements fail the session rather than restoring CPU
presentation. Timeout is five seconds and permits transport backpressure.

`tools/generate_mesa_present_patch.py` regenerates the patch from pristine
pinned winsys files and rejects changed source contexts. The changes retain
the winsys's existing requirement that callers serialize its socket writes;
the v1 path does not introduce concurrent command/resource streams.

The Linux CI demo swaps three 64x64 frames, validates at least three ordered PRESENT markers
at a diagnostic receiver, and requires zero `TRANSFER_GET`. A separate run
requests a red pixel with `glReadPixels` and verifies it still returns the GPU
result. The diagnostic receiver never displays or fences PRESENT; these gates
do not prove iOS presentation.
Mesa can also flush a frontbuffer at initialization. `frame_id` counts winsys
presentation events, not GLFW swap calls; the test checks consecutive IDs and
dimensions rather than assuming a one-to-one relationship.

The patch is deliberately opt-in through `REMOTEGPU_VTEST_LEGACY=1`. GitHub
Actions must run `git apply --check` against the pinned Mesa revision before
any Mesa build. The capability gate remains mandatory: a successful patch does
not prove that the resulting protocol-0 renderer exposes OpenGL 3.2 Core.
