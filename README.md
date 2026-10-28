# RemoteGPU

RemoteGPU aims to run the real Minecraft Java client on GPU-less Ubuntu while
a paired iPhone executes GPU rendering/display. The approved design sends a
restricted VirGL vtest profile over one ordered QUIC render stream, not video.
Real Ubuntu-originated single-frame and 7/12-frame remote draws have passed iPhone display acceptance;
Minecraft is not functional yet. No
Minecraft JVM or replacement game client is installed on the phone.

## Build policy

All compilation is performed by GitHub Actions. In particular, Mesa and iOS
dependency builds must never run on the Ubuntu compute host. Use **Actions →
Build Linux PoC → Run workflow** and download its `linux-poc-<commit>` artifact.
The workflow preserves Mesa compiler results with `ccache`, its pinned Meson
tool environment, Go module/build caches, and SwiftPM dependency/build caches.
It intentionally does not cache a generated Mesa build directory, because that
directory is runner-path sensitive.

The cache key includes the pinned Mesa revision, Mesa patches, and compiler
configuration. A change to any of those correctly causes a cold compiler
cache; a change limited to the Go, Swift, workflow packaging, or documentation
layers does not invalidate it.

## Status

Status as of 2026-10-28:

| Category | Evidence / remaining boundary |
| --- | --- |
| CI-verified | Linux rendering/transport, Mesa PRESENT/readback separation, native decoder/resource/fence lifetime. Linux software rendering is not phone hardware acceptance. |
| Device-verified (user reports) | A2.0 `98e65d1`: real VirGL GPU resource snapshot/isolation. A2.1 `3b5e80d`: actual Ubuntu GL 2.1/GLSL 120 frame over QUIC, iPhone18,3 / iOS 27.0.1, GPU Copy/IOSurface/Metal, correct visual output and GET=0. |
| Device-verified multi-frame | 7 frames at `9ed016c`, 12 frames at `acce896`: all PRESENTs completed, correct changing image, live hold >=120s, GET=0, user disconnect cleanup returned. [Evidence](docs/evidence/a21-multiframe-2026-10-28/README.md). |
| Implemented, device pending | A3.1 opt-in single-slot timer-driven GPU completion; one-click Keychain profile. Full same-process render reconnect is deferred, not passed by a QUIC-only connection. [Procedure/bounds](docs/a31-async-single-slot.md). |
| Known failed prerequisite | GLES 3.1/3.2 requests rejected; guest GLSL capset 130, below 150. Actual Ubuntu guest GL 3.2 Core acceptance remains pending. |
| Not implemented / accepted | A3 double buffers/overlapping throughput/ten-minute performance; Minecraft/input/audio/Mods. A3.1 is code, not phone acceptance. |
| Candidate experiments | MobileGlues + ANGLE Metal, MobileGL interfaces, UTM MoltenVK with a compatibility implementation; no renderer replacement or candidate acceptance. |

The current blocker does **not** imply remote GPU is impossible. Two independent
routes now guide development:

- **A — Remote PRESENT:** real Ubuntu-originated changing triangle with the
  current renderer, ordered GPU-only snapshots/display and bounded lifetimes.
  No initial GL 3.2 or 720p/30 requirement.
- **B — Graphics capability:** source interfaces and one isolated candidate
  probe at a time, then genuinely executable guest GL 3.2 Core/GLSL 150 before
  Minecraft. No spoofed versions/caps.

See [next-stage tasks](docs/next-stage-plan.md) and
[architecture/evidence records](docs/architecture.md). Existing ADRs, PoCs,
formal renderer and deployment configuration remain unchanged.

This repository contains a verified Linux transport PoC, its test suite, a
Mesa legacy-vtest patch, and the iOS protocol integration target. GitHub
Actions builds Mesa virpipe and virglrenderer, then verifies this exact path:

```text
Mesa virpipe -> RemoteGPU Unix proxy -> QUIC/TLS -> Linux diagnostic receiver
              -> virgl_test_server -> OpenGL 4.3 Core capability probe
```

The gate also requires non-zero vtest traffic in both proxy directions. The
diagnostic receiver is intentionally Linux-only and rejects `PRESENT` by
default. Its CI-only `-inspect-present` mode validates markers without displaying
them. The Mesa presentation-hook patch passed its Linux zero-presentation-readback gate; the
iOS ANGLE/IOSurface renderer passed the separate single-frame A2.1 device gate.

Read [docs/architecture.md](docs/architecture.md) before building.

The shared native protocol-0 decoder now lives in
`ios/Renderer/RGPUVTestSession.cpp`. It calls virglrenderer directly and is
exercised by sanitizer tests in CI. **Native vtest rendering gate** reuses a
verified Linux PoC artifact and compiles only the adapter, then runs the real
triangle and application-readback checks over QUIC. This avoids rebuilding
Mesa/virglrenderer while iterating on the endpoint. See
[ios/README.md](ios/README.md#native-vtest-adapter-gate) for its safety boundary.
The iPhone capability endpoint connects this module to QUIC but deliberately
rejects PRESENT/readback in that diagnostic mode. Formal resource snapshot/
display is implemented in a separate bounded synchronous A2.1 mode, with an
opt-in A3.1 single-slot asynchronous experiment; Minecraft
is not functional yet. See [multi-frame device procedure](docs/a21-remote-present.md#a21-final-multi-frame-batch).

Retained pre-A2 local diagnostic build: [run 38245180997](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38245180997)
at `816bf85`; the user subsequently reported corrected local orientation and
the GLES request results. The subsequently accepted A2.1 app is run
[39101559555](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/39101559555)
at `3b5e80d`; its [archived device evidence](docs/evidence/a21-single-frame-2026-10-18/README.md)
does not substitute for the NEW multi-frame batch IPA. Historical CI/pinned-source evidence remains in
[architecture.md](docs/architecture.md#retained-ci-and-source-evidence).

## Fast path

Reference instructions only: this development round does not change DNS, TLS,
firewall or production services. **Connect Capability Probe** is not a remote
display mode; swapping demos must use **Connect Remote Display**, not that
capability-only mode. The remote-display form now defaults to isolated UDP4434.

GitHub Actions performs compilation and tests. For deployment, obtain the
artifact from a successful Action run and start it on the Ubuntu server:

```sh
./remotegpu-proxy \
  -unix /tmp/.virgl_test \
  -listen :4433 \
  -cert server.crt -key server.key \
  -pairing-token "replace-with-a-long-random-secret"
```

The proxy emits one protocol-statistics line per second by default. Use
`-stats-interval=5s` for longer intervals or `-stats-interval=0` to disable it.

The iPhone opens one QUIC bidirectional stream and sends a `HELLO` envelope
with the same pairing token. The proxy then bridges raw vtest bytes in both
directions. `PRESENT` envelopes can only travel from the Linux side to iOS on
that same ordered stream.

Never expose this development token or a self-signed certificate to the public
Internet. Production pairing must use device keys and a trusted certificate.
