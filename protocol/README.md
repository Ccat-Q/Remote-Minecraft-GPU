# Protocol ownership

`internal/protocol` is the authoritative Linux implementation of the v1
envelope. The Swift file under `ios/RemoteGPU/Protocol.swift` mirrors it and
must be updated in the same change.

Do not add a vtest opcode. RemoteGPU envelope types are outside the vtest
payload and are versioned independently.
