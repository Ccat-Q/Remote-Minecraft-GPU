import Foundation

// Keep this file byte-for-byte compatible with internal/protocol.
enum RemoteGPUType: UInt8, Equatable { case hello = 1, vtestBytes = 2, present = 3, error = 4 }

enum RemoteGPUProtocolError: Error, Equatable {
    case invalidMagic
    case unknownType(UInt8)
    case payloadTooLarge
    case invalidVTestChunk
    case invalidPresent
    case sequenceGap(expected: UInt64, received: UInt64)
}

struct RemoteGPUEnvelope: Equatable {
    static let magic = Data([0x52, 0x47, 0x50, 0x31]) // RGP1
    let type: RemoteGPUType
    let flags: UInt8
    let payload: Data

    func encoded() -> Data {
        precondition(payload.count <= 16 << 20)
        var output = Self.magic
        output.append(type.rawValue)
        output.append(flags)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(payload)
        return output
    }
}

final class RemoteGPUStreamDecoder {
    private static let headerSize = 10
    private static let maxPayload = 16 << 20
    private var pending = Data()

    func feed(_ bytes: Data) throws -> [RemoteGPUEnvelope] {
        pending.append(bytes)
        var envelopes: [RemoteGPUEnvelope] = []
        while pending.count >= Self.headerSize {
            guard pending.prefix(4) == RemoteGPUEnvelope.magic else {
                throw RemoteGPUProtocolError.invalidMagic
            }
            guard let type = RemoteGPUType(rawValue: pending[4]) else {
                throw RemoteGPUProtocolError.unknownType(pending[4])
            }
            let length = Int(pending[6]) << 24 | Int(pending[7]) << 16 |
                         Int(pending[8]) << 8 | Int(pending[9])
            guard length <= Self.maxPayload else { throw RemoteGPUProtocolError.payloadTooLarge }
            let total = Self.headerSize + length
            guard pending.count >= total else { break }
            let payload = pending.subdata(in: Self.headerSize..<total)
            envelopes.append(RemoteGPUEnvelope(type: type, flags: pending[5], payload: payload))
            pending.removeSubrange(0..<total)
        }
        return envelopes
    }
}

// The QUIC receiver feeds vtestBytes directly into the vtest server. A Present
// waits until afterSequence has been consumed and the renderer fence signals.
struct RemoteGPUPresent {
    let frameID: UInt64
    let resourceID: UInt64
    let afterSequence: UInt64
    let level: UInt32
    let layer: UInt32
    let x: UInt32
    let y: UInt32
    let width: UInt32
    let height: UInt32

    init(payload: Data) throws {
        guard payload.count == 48 else { throw RemoteGPUProtocolError.invalidPresent }
        func u64(_ at: Int) -> UInt64 {
            payload[at..<(at + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func u32(_ at: Int) -> UInt32 {
            payload[at..<(at + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        frameID = u64(0); resourceID = u64(8); afterSequence = u64(16)
        level = u32(24); layer = u32(28); x = u32(32); y = u32(36)
        width = u32(40); height = u32(44)
    }
}

struct RemoteGPUVTestChunk {
    let sequence: UInt64
    let bytes: Data

    init(payload: Data) throws {
        guard payload.count >= 8 else { throw RemoteGPUProtocolError.invalidVTestChunk }
        sequence = payload.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
        bytes = payload.subdata(in: 8..<payload.count)
    }

    init(sequence: UInt64, bytes: Data) {
        self.sequence = sequence
        self.bytes = bytes
    }

    var envelope: RemoteGPUEnvelope {
        var payload = Data()
        var value = sequence.bigEndian
        withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
        payload.append(bytes)
        return RemoteGPUEnvelope(type: .vtestBytes, flags: 0, payload: payload)
    }
}

// The renderer supplies `submit` and `fenceCompleted`. This type keeps all
// presentation ordering outside virglrenderer and never guesses a resource.
final class RemoteGPUFrameOrder {
    private(set) var processedSequence: UInt64 = 0
    private var waiting: [RemoteGPUPresent] = []

    func consumeVTest(_ payload: Data, submit: (Data) throws -> Void) throws {
        let chunk = try RemoteGPUVTestChunk(payload: payload)
        let expected = processedSequence + 1
        guard chunk.sequence == expected else {
            throw RemoteGPUProtocolError.sequenceGap(expected: expected, received: chunk.sequence)
        }
        try submit(chunk.bytes)
        processedSequence = chunk.sequence
    }

    func enqueuePresent(_ payload: Data) throws { waiting.append(try RemoteGPUPresent(payload: payload)) }

    func readyToPresent(fenceCompleted: (RemoteGPUPresent) -> Bool) -> [RemoteGPUPresent] {
        var ready: [RemoteGPUPresent] = []
        while let next = waiting.first,
              next.afterSequence <= processedSequence,
              fenceCompleted(next) {
            ready.append(next)
            waiting.removeFirst()
        }
        return ready
    }
}
