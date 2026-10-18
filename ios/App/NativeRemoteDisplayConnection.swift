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
    var onReport: ((String, Bool) -> Void)?
    var onDisplayed: ((UInt64) -> Void)?

    init(host: String, port: UInt16, token: String, layer: CAMetalLayer) {
        self.host = host; self.port = port; self.token = token; self.layer = layer
    }
    func start() {
        rendererQueue.async {
            self.evidence = RemoteGPUDisplayEvidence(sessionID: self.sessionID, startedAt: ProcessInfo.processInfo.systemUptime)
            guard !self.closed && !self.cancellation.isCancelled else { self.finish("Cancelled before start"); return }
            do {
                self.endpoint = try RGPURemoteDisplayEndpoint.create(cancellation: self.cancellation)
                self.header = self.endpoint?.hostReport ?? ""
                self.header += "\nA21_SESSION session=\(self.sessionID) clock=local_monotonic\n"
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
                        defer { complete() }
                        self.consume(batch)
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
        let counters = "\nVTEST processed=\(order.processedSequence) displayed PRESENT=\(order.displayedFrame)\nReceived vtest=\(received) reply bytes=\(sent) batch high-water=\(highWaterBatch) bytes\nOne batch in flight; one snapshot at a time; max 16 PRESENTs. No per-frame network ACK.\n"
        if let activity = streamActivity.latest { evidence?.receivedVTest(at: activity) }
        let hold = evidence?.holdLine(at: ProcessInfo.processInfo.systemUptime, live: !closed && !cancellation.isCancelled) ?? ""
        let text = header + "\n" + status + counters + hold + "\n" + history.joined(separator: "\n")
        DispatchQueue.main.async { self.onReport?(text, finished) }
    }
    private func observeHold() {
        guard !closed && !cancellation.isCancelled && order.displayedFrame > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let activity = streamActivity.latest { evidence.receivedVTest(at: activity) }
        let milestone = evidence.quietSeconds(at: now) >= 120 && holdMilestone != order.displayedFrame
        if milestone {
            holdMilestone = order.displayedFrame
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
        cancellation.cancel()
        order.cancel()
        transport?.close(); transport = nil
        append(endpoint?.close() ?? "No native session allocated")
        endpoint = nil
        append("A21_SESSION_CLOSED session=\(sessionID) displayed=\(order.displayedFrame) cleanup_returned=YES reason=\(status)")
        report(status, finished: true)
    }
    private func consume(_ batch: [RemoteGPUEnvelope]) {
        guard !closed else { return }
        do {
            highWaterBatch = max(highWaterBatch, batch.reduce(0) { $0 + $1.payload.count + 10 })
            for envelope in batch {
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
                    // This blocks only the serialized diagnostic renderer, not
                    // UIKit/network. NO later native command is submitted here.
                    let began = ProcessInfo.processInfo.systemUptime
                    append(try endpoint.present(envelope.payload, layer: layer))
                    try order.completePresent(present)
                    append(try evidence.completed(present, began: began, ended: ProcessInfo.processInfo.systemUptime))
                    holdMilestone = nil
                    let frame = present.frameID
                    DispatchQueue.main.async { self.onDisplayed?(frame) }
                    // Report EVERY completed PRESENT, even if one bounded
                    // network batch contains multiple frames. Never just count receives.
                    report("REMOTE FRAME DISPLAYED; confirm image/frame in screen recording. Session remains open.")
                case .hello, .error: throw RemoteGPUProtocolError.invalidPresent
                }
            }
        } catch { finish("REMOTE DISPLAY FAILED: \(String(describing: error))\n\(error.localizedDescription)") }
    }
}
