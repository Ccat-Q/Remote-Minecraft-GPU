# RemoteGPU

RemoteGPU aims to run the real Minecraft Java client on GPU-less Ubuntu while
a paired iPhone executes GPU rendering/display. The approved design sends a
restricted VirGL vtest profile over one ordered QUIC render stream, not video.
Minecraft and end-to-end remote iPhone display are not functional yet; no
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

Status as of 2026-10-13:

| Category | Evidence / remaining boundary |
| --- | --- |
| CI-verified | Linux rendering/transport, Mesa PRESENT/readback separation, native decoder/resource/fence lifetime. Linux software rendering is not phone hardware acceptance. |
| Device-verified (user reports) | iPhone 17 / iOS 27.0.1 local ANGLE/IOSurface/Metal triangle, corrected orientation, native context/caps; not Ubuntu-originated remote draws. |
| Implemented, runtime pending | iPhone capability-only QUIC/EGL endpoint. Builds pass; end-to-end device network acceptance is pending. |
| Known failed prerequisite | GLES 3.1/3.2 requests rejected; guest GLSL capset 130, below 150. Actual Ubuntu guest GL 3.2 Core acceptance remains pending. |
| Not implemented / accepted | Formal remote snapshots/PRESENT, independent completion, sustained remote display, Minecraft/input/audio/Mods. |
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
iOS ANGLE/IOSurface renderer remains an implementation milestone.

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
display is not implemented; Minecraft is not functional yet.

Latest app build: [run 38245180997](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/38245180997)
at `816bf85`; the user subsequently reported corrected local orientation and
the GLES request results. Historical CI/pinned-source evidence remains in
[architecture.md](docs/architecture.md#retained-ci-and-source-evidence).

## Fast path

Reference instructions only: this development round does not change DNS, TLS,
firewall or production services. **Connect Capability Probe** is not a remote
display mode; swapping demos are rejected until route A's adapter exists.

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
