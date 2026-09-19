# Architecture

## Data flow

```text
Minecraft Java 1.21.1 / LWJGL / GLFW
  -> Mesa virpipe + vtest winsys
  -> Unix socket
  -> RemoteGPU Linux proxy
  -> QUIC/TLS render stream
  -> RemoteGPU iOS vtest endpoint
  -> virglrenderer-ios -> ANGLE Metal -> IOSurface
  -> MTLTexture -> CAMetalLayer
```

`PRESENT` is emitted by the Mesa vtest winsys presentation path, never by
GLFW. The hook includes its cumulative vtest byte offset. The Linux proxy waits
until it has forwarded that offset, assigns `after_sequence`, and emits the
marker on the same QUIC stream. The iOS endpoint waits for that sequence and
its renderer fence before displaying the IOSurface.

## Wire format

Every envelope is big-endian:

| Field | Size |
| --- | --- |
| magic (`RGP1`) | 4 bytes |
| type | 1 byte |
| flags | 1 byte |
| payload length | 4 bytes |
| payload | variable |

Types are `HELLO`, `VTEST_BYTES`, `PRESENT`, and `ERROR`. `VTEST_BYTES` starts
with an eight-byte sequence followed by original vtest bytes. A `HELLO` is the
first message sent by iOS and contains the pairing token. `PRESENT` contains
`frame_id`, `resource_id`, `level`, `layer`, dirty rectangle and
`after_sequence`.

## v1 safety boundary

The proxy reconstructs and validates legacy client vtest frames before they
reach QUIC. It rejects protocol negotiation other than vtest protocol 0,
mmap-able resources, blob resources, FD export, DRM sync, eventfd and unknown
commands. Before Minecraft is attempted, a trace determines whether protocol
0 can create a GL 3.2 Core context without an FD. If it cannot, the project
stops at this gate and expands Mesa's network-safe winsys; it must not pretend
a Unix FD is portable over QUIC.

## Validation gates

1. Local virpipe/vtest trace and supported-profile report.
2. iOS ANGLE/IOSurface render trace replay.
3. End-to-end GL capability test: GL >= 3.2 Core, GLSL, FBO, VAO, instancing,
   sync and query support.
4. Mesa presentation hook with zero presentation readback bytes.
5. Vanilla 1.21.1, 720p/30, 10 minutes over Wi-Fi on the 2 vCPU/4 GiB host.
6. 5G functional run with RTT, jitter, stall and bandwidth reporting.

All builds and compilation run in GitHub Actions. The Ubuntu server only runs
downloaded CI artifacts and target-environment checks; it does not build Mesa,
ANGLE, the proxy or the iOS application.

GitHub Actions caches Go modules/build output using `go.sum`, SwiftPM's build
and dependency directories using its resolved dependency manifest, and Mesa
compiler output using `ccache`. The Mesa cache key contains the pinned commit,
our Mesa patch set, and ccache compiler configuration; it intentionally omits
generated Meson build directories, which contain absolute runner paths. Future
Mesa/ANGLE build workflows must likewise key compiler caches on pinned commits,
toolchain version and build flags; never key them only by branch name.
