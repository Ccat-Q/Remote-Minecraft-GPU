# Mesa vtest presentation patch contract

Apply `0001-remotegpu-force-legacy-vtest.patch` only to the pinned Mesa source
after the local vtest trace has selected the no-FD profile. It changes protocol
negotiation only. The separate presentation patch is not implemented yet and
must target `src/gallium/winsys/virgl/vtest/virgl_vtest_winsys.c`, specifically
`virgl_vtest_flush_frontbuffer()`.

The future presentation patch must replace only the presentation-only call path:

```text
TRANSFER_GET -> busy wait -> displaytarget CPU copy -> displaytarget_display
```

with a Unix datagram sent to `REMOTEGPU_PRESENT_SOCKET`:

```c
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

The patch is deliberately opt-in through `REMOTEGPU_VTEST_LEGACY=1`. GitHub
Actions must run `git apply --check` against the pinned Mesa revision before
any Mesa build. The capability gate remains mandatory: a successful patch does
not prove that the resulting protocol-0 renderer exposes OpenGL 3.2 Core.
