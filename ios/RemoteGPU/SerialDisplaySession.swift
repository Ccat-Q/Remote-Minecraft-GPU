import Foundation

// A2.1 admission, not the old speculative/pending presentation queue. A PRESENT
// must refer to the EXACT sequence already executed at its single-stream slot.
final class RemoteGPUSerialDisplayOrder {
    private(set) var processedSequence: UInt64 = 0
    private(set) var displayedFrame: UInt64 = 0
    private(set) var snapshotInProgress = false
    private var cancelled = false

    func consume(_ payload: Data, submit: (Data) throws -> Void) throws {
        guard !cancelled && !snapshotInProgress && processedSequence < UInt64.max else {
            throw RemoteGPUProtocolError.invalidVTestChunk
        }
        let chunk = try RemoteGPUVTestChunk(payload: payload)
        guard chunk.sequence == processedSequence + 1 && !chunk.bytes.isEmpty else {
            throw RemoteGPUProtocolError.sequenceGap(expected: processedSequence + 1, received: chunk.sequence)
        }
        try submit(chunk.bytes)
        processedSequence = chunk.sequence
    }

    func beginPresent(_ payload: Data) throws -> RemoteGPUPresent {
        let present = try RemoteGPUPresent(payload: payload)
        guard !cancelled && !snapshotInProgress && displayedFrame < 16 &&
            present.frameID == displayedFrame + 1 && present.afterSequence == processedSequence &&
            present.resourceID > 0 && present.resourceID <= UInt64(UInt32.max) &&
            present.level == 0 && present.layer == 0 && present.x == 0 && present.y == 0 &&
            present.width == 64 && present.height == 64 else { throw RemoteGPUProtocolError.invalidPresent }
        snapshotInProgress = true
        return present
    }

    func completePresent(_ present: RemoteGPUPresent) throws {
        guard !cancelled && snapshotInProgress && present.frameID == displayedFrame + 1 else {
            throw RemoteGPUProtocolError.invalidPresent
        }
        snapshotInProgress = false
        displayedFrame = present.frameID
    }
    func cancel() { cancelled = true }
}

// Exactly one decoded network batch may be in flight, including while native
// code waits for a GPU fence. The transport does NOT receive again until local
// completion. This is flow control, not an on-wire/per-frame ACK.
final class RemoteGPUBoundedIngress {
    static let byteBudget = (16 << 20) + (64 << 10)
    static let envelopeBudget = 4096
    private var nextTicket: UInt64 = 0
    private var activeTicket: UInt64?
    private(set) var highWaterBytes = 0
    private(set) var cancelled = false

    func admit(_ batch: [RemoteGPUEnvelope]) throws -> UInt64 {
        let bytes = batch.reduce(0) { $0 + $1.payload.count + 10 }
        guard !cancelled && activeTicket == nil && !batch.isEmpty &&
            batch.count <= Self.envelopeBudget && bytes <= Self.byteBudget else {
            throw RemoteGPUProtocolError.payloadTooLarge
        }
        nextTicket += 1
        activeTicket = nextTicket
        highWaterBytes = max(highWaterBytes, bytes)
        return nextTicket
    }
    // Duplicate/stale callbacks cannot admit another receive.
    func complete(_ ticket: UInt64) -> Bool {
        guard activeTicket == ticket else { return false }
        activeTicket = nil
        return !cancelled
    }
    func cancel() { cancelled = true }
}
