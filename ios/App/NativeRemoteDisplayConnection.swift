import Foundation
import QuartzCore

// Native renderer and its session live on exactly one serial queue. The
// network admits one bounded batch; later vtest cannot overtake a snapshot.
final class NativeRemoteDisplayConnection: @unchecked Sendable {
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
    var onReport: ((String, Bool) -> Void)?

    init(host: String, port: UInt16, token: String, layer: CAMetalLayer) {
        self.host = host; self.port = port; self.token = token; self.layer = layer
    }
    func start() {
        rendererQueue.async {
            guard !self.closed && !self.cancellation.isCancelled else { self.finish("Cancelled before start"); return }
            do {
                self.endpoint = try RGPURemoteDisplayEndpoint.create(cancellation: self.cancellation)
                self.header = self.endpoint?.hostReport ?? ""
                let connection = RemoteGPUQUICRenderConnection(host: self.host, port: self.port, pairingToken: self.token)
                self.transport = connection
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
                connection.start()
            } catch { self.finish("INIT FAILED: \(error.localizedDescription)") }
        }
    }
    func stop() {
        cancellation.cancel() // Immediate atomic signal even while rendererQueue waits.
        rendererQueue.async { self.finish("User cancelled display session") }
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
        let text = header + "\n" + status + counters + history.joined(separator: "\n")
        DispatchQueue.main.async { self.onReport?(text, finished) }
    }
    private func finish(_ status: String) {
        guard !closed else { return }
        closed = true
        cancellation.cancel()
        order.cancel()
        transport?.close(); transport = nil
        append(endpoint?.close() ?? "No native session allocated")
        endpoint = nil
        report(status, finished: true)
    }
    private func consume(_ batch: [RemoteGPUEnvelope]) {
        guard !closed else { return }
        do {
            highWaterBatch = max(highWaterBatch, batch.reduce(0) { $0 + $1.payload.count + 10 })
            var displayed = false
            for envelope in batch {
                guard !cancellation.isCancelled else { throw RemoteGPUProtocolError.invalidPresent }
                guard envelope.flags == 0 else { throw RemoteGPUProtocolError.invalidPresent }
                switch envelope.type {
                case .vtestBytes:
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
                    let present = try order.beginPresent(envelope.payload)
                    append("PRESENT received frame=\(present.frameID) resource=\(present.resourceID) after=\(present.afterSequence) processed=\(order.processedSequence)")
                    guard let endpoint else { throw RemoteGPUProtocolError.invalidPresent }
                    // This blocks only the serialized diagnostic renderer, not
                    // UIKit/network. NO later native command is submitted here.
                    append(try endpoint.present(envelope.payload, layer: layer))
                    try order.completePresent(present)
                    displayed = true
                case .hello, .error: throw RemoteGPUProtocolError.invalidPresent
                }
            }
            // At most 16 display reports: don't enqueue UI work for every chunk.
            if displayed { report("REMOTE FRAME DISPLAYED; visual confirmation pending. Session remains open; last drawable is retained by the display.") }
        } catch { finish("REMOTE DISPLAY FAILED: \(error.localizedDescription)") }
    }
}
