# ADR 0001: Use one ordered render stream for vtest and PRESENT

`PRESENT` must be ordered after the renderer commands that produce its image.
QUIC only guarantees ordering inside one stream. RemoteGPU therefore places
vtest payload bytes and `PRESENT` envelopes on one reliable bidirectional
render stream. Separate QUIC streams may carry audio and future caches, but
cannot carry an operation that affects render ordering.
