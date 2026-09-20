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

The target `PRESENT` design emits from the Mesa vtest winsys presentation path,
never GLFW. The hook will include its cumulative vtest byte offset. The Linux
proxy already waits until it has forwarded that offset, assigns
`after_sequence`, and emits the marker on the same QUIC stream. The iOS
endpoint already orders markers behind that sequence; the Mesa hook and the
iOS renderer adapter remain implementation gates before an end-to-end claim.

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

At the pinned Mesa revision, the legacy virpipe winsys connects to the literal
Unix path `/tmp/.virgl_test`; it does not honour a `VTEST_SOCKET` environment
variable. The first Linux gate therefore intentionally starts
`virgl_test_server` at that path. Remote deployment retains that local path
between Mesa and the proxy; making it configurable is a later Mesa winsys
change, not an assumed property of the existing driver.

## Validation gates

1. Linux diagnostic receiver test: Mesa virpipe -> RemoteGPU Unix proxy -> one
   ordered QUIC stream -> Linux vtest receiver -> virgl_test_server.
2. iOS ANGLE/IOSurface render trace replay.
3. End-to-end GL capability test: GL >= 3.2 Core, GLSL, FBO, VAO, instancing,
   sync and query support.
4. Mesa presentation hook with zero presentation readback bytes (not yet
   implemented in the current patch set).
5. Vanilla 1.21.1, 720p/30, 10 minutes over Wi-Fi on the 2 vCPU/4 GiB host.
6. 5G functional run with RTT, jitter, stall and bandwidth reporting.

All builds and compilation run in GitHub Actions. The Ubuntu server only runs
downloaded CI artifacts and target-environment checks; it does not build Mesa,
ANGLE, the proxy or the iOS application.

GitHub Actions caches Go modules/build output using `go.sum`, SwiftPM's build
and dependency directories using its resolved dependency manifest, the pinned
Meson tool virtual environment, and the Mesa/virglrenderer compiler output
using `ccache`. The cache namespace includes both pinned source revisions, the
Mesa patch set and ccache compiler configuration; it intentionally omits
generated Meson build directories, which contain absolute runner paths. Future
Mesa/ANGLE build workflows must likewise key compiler caches on pinned commits,
toolchain version and build flags; never key them only by branch name.

# Initial Linux PoC display scope

The downloadable Linux PoC artifact deliberately builds Mesa with the **X11**
platform only.  Its purpose is to prove the `virpipe → vtest → RemoteGPU`
transport path with the smallest useful OpenGL capability test; it is not yet
the Minecraft windowing environment.  Keeping Weston and Xwayland outside this
first gate avoids conflating a compositor/backend failure with a transport or
renderer failure, and avoids Mesa's unrelated `wayland-egl-backend` dependency.

Weston headless plus Xwayland remains the planned Minecraft integration stage,
after the remote renderer has passed the GL 3.2 Core and presentation gates.
