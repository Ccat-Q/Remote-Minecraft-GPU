# RemoteGPU glossary

## Compute Client

The unmodified Minecraft Java client running on Ubuntu. It owns JVM execution,
world state, Mods and CPU-side mesh generation.

## Renderer Endpoint

The iPhone application. It decodes the supported renderer protocol, performs
GPU work, presents locally, receives input and plays audio. It never runs a
Minecraft JVM.

## Render Stream

The single ordered, reliable QUIC stream carrying `RemoteGPU` envelopes that
contain vtest bytes and present markers. Ordering on this stream is the frame
ordering contract.

## vtest Payload

The original Mesa/virglrenderer binary protocol bytes. RemoteGPU does not
rewrite their contents.

## Presentation Readback

A `TRANSFER_GET` performed only to copy the front buffer back to Ubuntu for
local display. This is forbidden by RemoteGPU; application-requested readback
is distinct and remains observable.

## Supported vtest Profile

The explicitly traced subset of vtest that does not carry Unix file
descriptors or require shared mmap resources. Unsupported operations fail
closed.
