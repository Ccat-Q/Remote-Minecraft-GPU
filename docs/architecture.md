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
endpoint already orders markers behind that sequence. The Mesa hook patch is
now implemented and undergoing its Linux presentation gate; the iOS renderer
adapter remains an implementation gate before an end-to-end claim.

Mesa waits for a local Unix datagram acknowledgement after sending the marker.
The proxy responds only once the marker is queued on QUIC. This prevents later
resource destruction from overtaking the marker and adds no phone/GPU round
trip. The phone must still retain presentation resources through its renderer
fence and Metal display submission.

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

The current Mesa compatibility patch selects that profile only when
`REMOTEGPU_VTEST_LEGACY=1` is present in the compute-client environment. This
is mandatory for every RemoteGPU launch; without it Mesa negotiates its newer
local-only vtest protocol and the proxy intentionally closes the session.

At the pinned Mesa revision, the virpipe winsys reads `VTEST_SOCKET_NAME`
and falls back to `/tmp/.virgl_test`. It does not honour `VTEST_SOCKET`.
The Linux gate uses the default path between Mesa and the proxy; deployments
can select another local path with `VTEST_SOCKET_NAME`. This was verified from
the pinned winsys source exported by CI.

## Validation gates

1. Linux diagnostic receiver test: Mesa virpipe -> RemoteGPU Unix proxy -> one
   ordered QUIC stream -> Linux vtest receiver -> virgl_test_server.
2. iOS ANGLE/IOSurface render trace replay.
3. End-to-end GL capability test: GL >= 3.2 Core, GLSL, FBO, VAO, instancing,
   sync and query support.
4. Mesa presentation hook with zero presentation readback bytes. The Linux
   diagnostic test inspects three ordered markers, requires zero TRANSFER_GET,
   and separately verifies that application glReadPixels still reads a red
   pixel. Device presentation and fence completion remain separate gates.
5. Vanilla 1.21.1, 720p/30, 10 minutes over Wi-Fi on the 2 vCPU/4 GiB host.
6. 5G functional run with RTT, jitter, stall and bandwidth reporting.

Gate 1 is currently verified in GitHub Actions with protocol 0: the remote
renderer exposes OpenGL 4.3 Core / GLSL 4.30 and the proxy records non-zero
traffic in both directions. It is a transport/capability proof only: it uses a
Linux diagnostic receiver and has no `PRESENT` path.

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
