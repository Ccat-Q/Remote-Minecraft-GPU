import Foundation

enum RemoteGPUDisplayMode { case synchronous, asyncSingleSlot }
enum RemoteGPUCompletionStage: Int { case producer = 1, copy = 2, metal = 3, complete = 4 }

// This is the actual driver used by the app, not a packet callback. Dispatch
// coalesces timer events, so a busy owner queue cannot accumulate tick blocks.
final class RemoteGPUCompletionPulse {
    private let timer: DispatchSourceTimer
    init(queue: DispatchQueue, tick: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        timer.setEventHandler(handler: tick)
        timer.resume()
    }
    func cancel() { timer.cancel() }
    deinit { timer.cancel() }
}

struct RemoteGPUFrameTicket: Equatable {
    let generation: UInt64
    let frame: UInt64
    let resource: UInt64
    let after: UInt64
}

// Single owner queue. No vtest or new PRESENT is admitted while a ticket is
// active. Generation distinguishes reused numeric resource/frame handles.
final class RemoteGPUSingleSlotCompletion {
    private(set) var active: RemoteGPUFrameTicket?
    private(set) var stage: RemoteGPUCompletionStage = .complete
    private(set) var polls = 0
    private var generation: UInt64 = 0
    private var phaseStarted: TimeInterval = 0
    private var lastObserved: TimeInterval = 0
    private var cancelled = false
    static let phaseTimeout: TimeInterval = 10

    func begin(_ present: RemoteGPUPresent, at now: TimeInterval) throws -> RemoteGPUFrameTicket {
        guard !cancelled && active == nil && generation < UInt64.max && now.isFinite else {
            throw RemoteGPUProtocolError.invalidPresent
        }
        generation += 1
        let ticket = RemoteGPUFrameTicket(generation: generation, frame: present.frameID,
                                         resource: present.resourceID, after: present.afterSequence)
        active = ticket; stage = .producer; phaseStarted = now; lastObserved = now; polls = 0
        return ticket
    }
    func observe(_ ticket: RemoteGPUFrameTicket, stage next: RemoteGPUCompletionStage, at now: TimeInterval) throws {
        guard !cancelled && active == ticket && now.isFinite && now >= lastObserved &&
            now - phaseStarted < Self.phaseTimeout && next.rawValue >= stage.rawValue &&
            next.rawValue <= stage.rawValue + 1 else { throw RemoteGPUProtocolError.invalidPresent }
        polls += 1; lastObserved = now
        if next != stage { phaseStarted = now; stage = next }
        if next == .complete { active = nil }
    }
    func cancel() { cancelled = true; active = nil }
}

// Holds the unconsumed suffix of exactly ONE admitted network batch, including
// its local receive-completion lease. GPU timer ticks resume this cursor. No
// on-wire ACK, state-command dropping, or packet-driven completion is involved.
final class RemoteGPUDisplayBatchCursor {
    private var batch: [RemoteGPUEnvelope] = []
    private var index = 0
    private var completion: (() -> Void)?
    var isActive: Bool { completion != nil }
    var remaining: Int { batch.count - index }
    private(set) var highWaterBytes = 0

    func admit(_ next: [RemoteGPUEnvelope], complete: @escaping () -> Void) throws {
        let bytes = next.reduce(0) { $0 + $1.payload.count + 10 }
        guard !isActive && !next.isEmpty && next.count <= RemoteGPUBoundedIngress.envelopeBudget &&
            bytes <= RemoteGPUBoundedIngress.byteBudget else { throw RemoteGPUProtocolError.payloadTooLarge }
        batch = next; index = 0; completion = complete
        highWaterBytes = max(highWaterBytes, bytes)
    }
    func next() -> RemoteGPUEnvelope? {
        guard index < batch.count else { return nil }
        defer { index += 1 }
        return batch[index]
    }
    func release() {
        let done = completion
        completion = nil; batch = []; index = 0
        done?() // State cleared BEFORE callback; exactly once on success/cancel.
    }
}
