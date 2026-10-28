import Foundation
import QuartzCore

// Native renderer and its session live on exactly one serial queue. The
// network admits one bounded batch; later vtest cannot overtake a snapshot.
final class NativeRemoteDisplayConnection: @unchecked Sendable {
    let sessionID = UUID().uuidString
    private let rendererQueue = DispatchQueue(label: "org.remotegpu.remote-display", qos: .userInitiated)
    private let cancellation = RGPUDisplayCancellation()
    private let order = RemoteGPUSerialDisplayOrder()
    private var endpoint: RGPURemoteDisplayEndpoint?
    private var transport: RemoteGPUQUICRenderConnection?
    private let host: String
    private let port: UInt16
    private let token: String
    private let layer: CAMetalLayer
    private var closed = false
    private var replySequence: UInt64 = 0
    private var received: UInt64 = 0
    private var sent: UInt64 = 0
    private var highWaterBatch = 0
    private var header = ""
    private var history: [String] = []
    private var timer: DispatchSourceTimer?
    private let streamActivity = RemoteGPUStreamActivity()
    private var evidence: RemoteGPUDisplayEvidence!
    private var lastHoldReport: TimeInterval = 0
    private var holdMilestone: UInt64?
    private var holdCheckpoint = 0
    private let mode: RemoteGPUDisplayMode
    private let batchCursor = RemoteGPUDisplayBatchCursor()
    private let completionState = RemoteGPUSingleSlotCompletion()
    private var completionTimer: RemoteGPUCompletionPulse?
    private var asyncPresent: RemoteGPUPresent?
    private var asyncBegan: TimeInterval = 0
    var onReport: ((String, Bool) -> Void)?
    var onDisplayed: ((UInt64) -> Void)?

    init(host: String, port: UInt16, token: String, layer: CAMetalLayer, mode: RemoteGPUDisplayMode = .synchronous) {
        self.host = host; self.port = port; self.token = token; self.layer = layer
        self.mode = mode
    }
    func start() {
        rendererQueue.async {
            self.evidence = RemoteGPUDisplayEvidence(sessionID: self.sessionID, startedAt: ProcessInfo.processInfo.systemUptime)
            guard !self.closed && !self.cancellation.isCancelled else { self.finish("Cancelled before start"); return }
            do {
                self.endpoint = try RGPURemoteDisplayEndpoint.create(cancellation: self.cancellation)
                self.header = self.endpoint?.hostReport ?? ""
                if self.mode == .asyncSingleSlot {
                    self.header = self.header.replacingOccurrences(of: "A2.1 REAL REMOTE DISPLAY (bounded diagnostic, not A3)",
                        with: "A3.1 ASYNC SINGLE-SLOT REMOTE DISPLAY (device acceptance pending; NOT double buffering)")
                }
                self.header += "\nA21_SESSION session=\(self.sessionID) clock=local_monotonic\n"
                self.header += "SCHEDULER=\(self.mode == .synchronous ? "A2.1_SYNC" : "A3.1_ASYNC_SINGLE_SLOT")\n"
                self.header += "HOLD_POLICY default_observation_s=30 checkpoint_interval_s=30; longer cases require actual measured quiet_s\n"
                let timer = DispatchSource.makeTimerSource(queue: self.rendererQueue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.observeHold() }
                self.timer = timer
                timer.resume()
                let connection = RemoteGPUQUICRenderConnection(host: self.host, port: self.port, pairingToken: self.token)
                self.transport = connection
                let activity = self.streamActivity
                connection.onStreamBytes = { activity.record(at: ProcessInfo.processInfo.systemUptime) }
                connection.onBatch = { [weak self] batch, complete in
                    guard let self else { complete(); return }
                    self.rendererQueue.async {
                        guard !self.closed else { complete(); return }
                        do {
                            try self.batchCursor.admit(batch, complete: complete)
                            self.consumePendingBatch()
                        } catch {
                            self.finish("BATCH ADMISSION FAILED: \(error)")
                            complete()
                        }
                    }
                }
                connection.onEvent = { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .failed, .closed: self.cancellation.cancel()
                    default: break
                    }
                    self.rendererQueue.async {
                        guard !self.closed else { return }
                        switch event {
                        case .ready: self.report("QUIC ready; run Ubuntu gl-remote-present. Waiting for REAL vtest/PRESENT.")
                        case .failed(let error): self.finish("NETWORK FAILED: \(String(describing: error))")
                        case .closed: self.finish("Peer stream ended. Cleaning up, NOT a successful live-session hold or reconnect.")
                        case .envelope: self.finish("Unexpected unbounded envelope delivery")
                        }
                    }
                }
                self.report("CONNECTING to \(self.host):\(self.port). Previous screen content is NOT remote evidence; displayed PRESENT=0 until real commands arrive.")
                connection.start()
            } catch { self.finish("INIT FAILED: \(error.localizedDescription)") }
        }
    }
    func stop(reason: String = "User cancelled display session") {
        cancellation.cancel() // Immediate atomic signal even while rendererQueue waits.
        rendererQueue.async { self.finish(reason) }
    }
    private func append(_ text: String) {
        history.append(text)
        // Finite diagnostic transcript; no unbounded UI callback/command queue.
        while history.count > 512 || history.reduce(0, { $0 + $1.utf8.count }) > 256 << 10 {
            history.removeFirst()
        }
    }
    private func report(_ status: String, finished: Bool = false) {
        let counters = "\nVTEST processed=\(order.processedSequence) displayed PRESENT=\(order.displayedFrame)\nReceived vtest=\(received) reply bytes=\(sent) batch high-water=\(highWaterBatch) bytes\nOne batch in flight; one snapshot at a time; max 16 PRESENTs. No per-frame network ACK.\n" +
            (mode == .asyncSingleSlot ? "A3_QUEUE slots=1 in_use=\(asyncPresent == nil ? 0 : 1) pending_envelopes=\(batchCursor.remaining) stage=\(completionState.stage) polls=\(completionState.polls)\n" : "")
        if let activity = streamActivity.latest { evidence?.receivedVTest(at: activity) }
        let hold = evidence?.holdLine(at: ProcessInfo.processInfo.systemUptime, live: !closed && !cancellation.isCancelled) ?? ""
        let text = header + "\n" + status + counters + hold + "\n" + history.joined(separator: "\n")
        DispatchQueue.main.async { self.onReport?(text, finished) }
    }
    private func observeHold() {
        guard !closed && !cancellation.isCancelled && order.displayedFrame > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let activity = streamActivity.latest { evidence.receivedVTest(at: activity) }
        let checkpoint = evidence.holdCheckpoint(at: now)
        if checkpoint < holdCheckpoint { holdCheckpoint = 0 }
        let milestone = checkpoint > 0 && (holdMilestone != order.displayedFrame || checkpoint > holdCheckpoint)
        if milestone {
            holdMilestone = order.displayedFrame
            holdCheckpoint = checkpoint
            append(evidence.holdLine(at: now, live: true))
        }
        if milestone || now - lastHoldReport >= 5 {
            lastHoldReport = now
            report("LIVE HOLD OBSERVATION; confirm last image remains visible. No pixel readback; not automatic visual acceptance.")
        }
    }
    private func finish(_ status: String) {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        completionTimer?.cancel(); completionTimer = nil
        cancellation.cancel()
        completionState.cancel()
        order.cancel()
        transport?.close(); transport = nil
        batchCursor.release()
        append(endpoint?.close() ?? "No native session allocated")
        endpoint = nil
        asyncPresent = nil
        append("A21_SESSION_CLOSED session=\(sessionID) displayed=\(order.displayedFrame) cleanup_returned=YES reason=\(status)")
        report(status, finished: true)
    }
    private func consumePendingBatch() {
        guard !closed else { return }
        do {
            highWaterBatch = max(highWaterBatch, batchCursor.highWaterBytes)
            while let envelope = batchCursor.next() {
                guard !cancellation.isCancelled else { throw RemoteGPUProtocolError.invalidPresent }
                if envelope.flags != 0 { append("Rejected envelope type=\(envelope.type) flags=\(envelope.flags)") }
                guard envelope.flags == 0 else { throw RemoteGPUProtocolError.invalidPresent }
                switch envelope.type {
                case .vtestBytes:
                    evidence.receivedVTest(at: ProcessInfo.processInfo.systemUptime)
                    try order.consume(envelope.payload) { bytes in
                        guard let endpoint else { throw RemoteGPUProtocolError.invalidVTestChunk }
                        received += UInt64(bytes.count)
                        for reply in try endpoint.submit(bytes) {
                            replySequence += 1; sent += UInt64(reply.count)
                            transport?.sendVTestReply(sequence: replySequence, bytes: reply)
                        }
                    }
                    append("VTEST processed seq=\(order.processedSequence)")
                case .present:
                    let requested = try RemoteGPUPresent(payload: envelope.payload)
                    append("PRESENT received frame=\(requested.frameID) resource=\(requested.resourceID) after=\(requested.afterSequence) processed=\(order.processedSequence)")
                    let present = try order.beginPresent(envelope.payload)
                    guard let endpoint else { throw RemoteGPUProtocolError.invalidPresent }
                    if mode == .asyncSingleSlot {
                        asyncPresent = present
                        asyncBegan = ProcessInfo.processInfo.systemUptime
                        let ticket = try completionState.begin(present, at: asyncBegan)
                        try endpoint.beginAsyncPresent(envelope.payload, layer: layer)
                        append("A3_ENQUEUED frame=\(ticket.frame) resource=\(ticket.resource) after=\(ticket.after) generation=\(ticket.generation); snapshot barrier HELD")
                        startCompletionDriver(ticket)
                        return // Retain batch suffix AND receive lease; timer resumes it.
                    }
                    // This blocks only the serialized diagnostic renderer, not
                    // UIKit/network. NO later native command is submitted here.
                    let began = ProcessInfo.processInfo.systemUptime
                    append(try endpoint.present(envelope.payload, layer: layer))
                    try order.completePresent(present)
                    append(try evidence.completed(present, began: began, ended: ProcessInfo.processInfo.systemUptime))
                    holdMilestone = nil; holdCheckpoint = 0
                    let frame = present.frameID
                    DispatchQueue.main.async { self.onDisplayed?(frame) }
                    // Report EVERY completed PRESENT, even if one bounded
                    // network batch contains multiple frames. Never just count receives.
                    report("REMOTE FRAME DISPLAYED; confirm image/frame in screen recording. Session remains open.")
                case .hello, .error: throw RemoteGPUProtocolError.invalidPresent
                }
            }
            batchCursor.release()
        } catch { finish("REMOTE DISPLAY FAILED: \(String(describing: error))\n\(error.localizedDescription)") }
    }

    private func startCompletionDriver(_ ticket: RemoteGPUFrameTicket) {
        completionTimer = RemoteGPUCompletionPulse(queue: rendererQueue) { [weak self] in self?.pollGPU(ticket) }
    }
    private func pollGPU(_ ticket: RemoteGPUFrameTicket) {
        guard !closed && completionState.active == ticket else { return } // Stale callback is inert.
        do {
            guard !cancellation.isCancelled, let endpoint, let present = asyncPresent,
                  present.frameID == ticket.frame && present.resourceID == ticket.resource &&
                  present.afterSequence == ticket.after else { throw RemoteGPUProtocolError.invalidPresent }
            // Native restores/unbinds EGL on EVERY call, even when this serial
            // queue runs on a different OS thread. Polls use zero CPU wait.
            let result = try endpoint.pollAsyncPresent()
            guard let phase = RemoteGPUCompletionStage(rawValue: Int(endpoint.asyncPresentStage)) else {
                throw RemoteGPUProtocolError.invalidPresent
            }
            try completionState.observe(ticket, stage: phase, at: ProcessInfo.processInfo.systemUptime)
            guard phase == .complete else { return }
            guard !result.isEmpty else { throw RemoteGPUProtocolError.invalidPresent }
            completionTimer?.cancel(); completionTimer = nil
            append(result)
            try order.completePresent(present)
            append(try evidence.completed(present, began: asyncBegan, ended: ProcessInfo.processInfo.systemUptime))
            append("A3_COMPLETED frame=\(ticket.frame) generation=\(ticket.generation) polls=\(completionState.polls); snapshot barrier RELEASED; slots_in_use=0")
            asyncPresent = nil; holdMilestone = nil; holdCheckpoint = 0
            DispatchQueue.main.async { self.onDisplayed?(ticket.frame) }
            report("A3 SINGLE-SLOT FRAME COMPLETED; visual acceptance required. No new packet needed for GPU progress.")
            consumePendingBatch()
        } catch { finish("ASYNC DISPLAY FAILED: \(error.localizedDescription)") }
    }
}
