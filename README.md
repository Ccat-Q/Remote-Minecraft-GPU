# RemoteGPU

RemoteGPU runs a Java Minecraft client on Ubuntu while a paired iPhone performs
rendering and presentation. It transports a deliberately restricted VirGL
vtest profile over one ordered QUIC render stream; it is not video streaming.

## Build policy

All compilation is performed by GitHub Actions. In particular, Mesa and iOS
dependency builds must never run on the Ubuntu compute host. Use **Actions →
Build Linux PoC → Run workflow** and download its `linux-poc-<commit>` artifact.
The workflow preserves Mesa compiler results with `ccache`, Go module/build
caches, and SwiftPM dependency/build caches. It intentionally does not cache a
generated Mesa build directory, because that directory is runner-path sensitive.

The cache key includes the pinned Mesa revision, Mesa patches, and compiler
configuration. A change to any of those correctly causes a cold compiler
cache; a change limited to the Go, Swift, workflow packaging, or documentation
layers does not invalidate it.

## Status

This repository contains the Linux protocol/proxy PoC, its test suite, a Mesa
legacy-vtest patch, and the iOS protocol integration target. The Mesa
presentation-hook patch and the iOS ANGLE/IOSurface renderer are the next
implementation milestones; they cannot be claimed verified from this Linux
workspace.

Read [docs/architecture.md](docs/architecture.md) before building.

## Fast path

GitHub Actions performs compilation and tests. For deployment, obtain the
artifact from a successful Action run and start it on the Ubuntu server:

```sh
./remotegpu-proxy \
  -unix /tmp/.virgl_test \
  -listen :4433 \
  -cert server.crt -key server.key \
  -pairing-token "replace-with-a-long-random-secret"
```

The iPhone opens one QUIC bidirectional stream and sends a `HELLO` envelope
with the same pairing token. The proxy then bridges raw vtest bytes in both
directions. `PRESENT` envelopes can only travel from the Linux side to iOS on
that same ordered stream.

Never expose this development token or a self-signed certificate to the public
Internet. Production pairing must use device keys and a trusted certificate.
