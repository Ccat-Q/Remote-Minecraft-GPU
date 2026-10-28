import Foundation

struct RemoteGPUBufferedTicket: Equatable {
    let slot: Int
    let generation: UInt64
    let frame: UInt64
    let resource: UInt64
    let after: UInt64
}

// Wire admission and renderer-slot identity are separate. A snapshot releases
// the source barrier, NOT the IOSurface slot or the display-order requirement.
final class RemoteGPUBufferedDisplayOrder {
    private struct Pending {
        let present: RemoteGPUPresent
        var ticket: RemoteGPUBufferedTicket?
        var snapshot = false
    }
    private var pending: [UInt64: Pending] = [:]
    private(set) var processedSequence: UInt64 = 0
    private(set) var acceptedFrame: UInt64 = 0
    private(set) var snapshottedFrame: UInt64 = 0
    private(set) var displayedFrame: UInt64 = 0
    private var generation: UInt64 = 0
    private var cancelled = false
    var sourceBarrier: Bool { acceptedFrame > snapshottedFrame }
    var inUse: Int { pending.count }
    var canAdvance: Bool { !cancelled && !sourceBarrier && pending.count < 2 }

    func consume(_ payload: Data, submit: (Data) throws -> Void) throws {
        guard canAdvance && processedSequence < UInt64.max else { throw RemoteGPUProtocolError.invalidVTestChunk }
        let chunk = try RemoteGPUVTestChunk(payload: payload)
        guard chunk.sequence == processedSequence + 1 && !chunk.bytes.isEmpty else {
            throw RemoteGPUProtocolError.sequenceGap(expected: processedSequence + 1, received: chunk.sequence)
        }
        try submit(chunk.bytes)
        processedSequence = chunk.sequence
    }
    func beginPresent(_ payload: Data) throws -> RemoteGPUPresent {
        let present = try RemoteGPUPresent(payload: payload)
        guard canAdvance && present.frameID == acceptedFrame + 1 && present.frameID <= 16 &&
            present.afterSequence == processedSequence && present.resourceID > 0 &&
            present.resourceID <= UInt64(UInt32.max) && present.level == 0 && present.layer == 0 &&
            present.x == 0 && present.y == 0 && present.width == 64 && present.height == 64 else {
            throw RemoteGPUProtocolError.invalidPresent
        }
        pending[present.frameID] = Pending(present: present)
        acceptedFrame = present.frameID
        return present
    }
    func admitted(_ ticket: RemoteGPUBufferedTicket) throws {
        guard !cancelled, var item = pending[ticket.frame], item.ticket == nil &&
            ticket.slot >= 0 && ticket.slot < 2 && ticket.generation > generation &&
            item.present.resourceID == ticket.resource && item.present.afterSequence == ticket.after &&
            !pending.values.contains(where: { $0.ticket?.slot == ticket.slot }) else {
            throw RemoteGPUProtocolError.invalidPresent
        }
        item.ticket = ticket; pending[ticket.frame] = item; generation = ticket.generation
    }
    func snapshot(_ ticket: RemoteGPUBufferedTicket) throws {
        guard !cancelled, var item = pending[ticket.frame], item.ticket == ticket && !item.snapshot &&
            ticket.frame == snapshottedFrame + 1 else { throw RemoteGPUProtocolError.invalidPresent }
        item.snapshot = true; pending[ticket.frame] = item; snapshottedFrame = ticket.frame
    }
    func complete(_ ticket: RemoteGPUBufferedTicket) throws -> RemoteGPUPresent {
        guard !cancelled, let item = pending[ticket.frame], item.ticket == ticket && item.snapshot &&
            ticket.frame == displayedFrame + 1 else { throw RemoteGPUProtocolError.invalidPresent }
        displayedFrame = ticket.frame; pending.removeValue(forKey: ticket.frame)
        return item.present
    }
    func cancel() { cancelled = true; pending.removeAll() }
}
