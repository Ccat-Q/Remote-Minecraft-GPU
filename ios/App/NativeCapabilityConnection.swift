import Foundation

// Capability-only receiver: no presentation path, no trust bypass, no version
// override. All renderer/session state is confined to rendererQueue. Native
// calls explicitly unbind EGL because a serial queue can migrate OS threads.
final class NativeCapabilityConnection: @unchecked Sendable {
    private let rendererQueue = DispatchQueue(label: "org.remotegpu.capability-session", qos: .userInitiated)
    private var endpoint: RGPUVTestEndpoint?
    private var transport: RemoteGPUQUICRenderConnection?
    private let host: String
    private let port: UInt16
    private let token: String
    private let order = RemoteGPUFrameOrder()
    private var replySequence: UInt64 = 0
    private var uploaded: UInt64 = 0
    private var downloaded: UInt64 = 0
    private var closed = false
    private var hostDetails = ""
    var onReport: ((String, Bool) -> Void)?

    init(host: String, port: UInt16, token: String) {
        self.host = host; self.port = port; self.token = token
    }
    func start() {
        rendererQueue.async {
            guard !self.closed else { return }
            do {
                self.endpoint = try RGPUVTestEndpoint.create()
                self.hostDetails = self.endpoint?.hostReport ?? ""
                let connection = RemoteGPUQUICRenderConnection(host: self.host, port: self.port, pairingToken: self.token)
                self.transport = connection
                connection.onEvent = { [weak self] event in
                    guard let self else { return }
                    self.rendererQueue.async { self.handle(event) }
                }
                self.report("Native renderer ready. Connecting to \(self.host):\(self.port)…", finished: false)
                connection.start()
            } catch { self.finish("INIT FAILED: \(error.localizedDescription)") }
        }
    }
    func stop() {
        rendererQueue.async { self.finish("Capability session stopped") }
    }
    private func report(_ message: String, finished: Bool) {
        let counters = "\nVtest sequences: \(order.processedSequence)\nReceived: \(uploaded) bytes\nReplies: \(downloaded) bytes\nGuest GL_VERSION/GLSL_VERSION must be read from Ubuntu's probe output."
        let text = message + "\n" + hostDetails + counters
        DispatchQueue.main.async { self.onReport?(text, finished) }
    }
    private func finish(_ message: String) {
        guard !closed else { return }
        closed = true
        endpoint = nil // Restore/delete EGL + virgl resources on rendererQueue.
        transport?.close()
        transport = nil
        report(message, finished: true)
    }
    private func handle(_ event: RemoteGPUConnectionEvent) {
        guard !closed else { return }
        do {
            switch event {
            case .ready:
                report("QUIC ready; waiting for Ubuntu capability probe.", finished: false)
            case .failed(let error): finish("CONNECTION FAILED: \(error.localizedDescription)")
            case .closed: finish("Ubuntu closed capability session")
            case .envelope(let envelope):
                guard envelope.type == .vtestBytes else {
                    finish(envelope.type == .present ?
                        "UNSUPPORTED: PRESENT is not implemented in capability-only mode. No frame was displayed." :
                        "Rejected unexpected server envelope")
                    return
                }
                try order.consumeVTest(envelope.payload) { bytes in
                    guard let endpoint else { throw RemoteGPUProtocolError.invalidVTestChunk }
                    uploaded += UInt64(bytes.count)
                    for reply in try endpoint.submit(bytes) {
                        replySequence += 1
                        downloaded += UInt64(reply.count)
                        transport?.sendVTestReply(sequence: replySequence, bytes: reply)
                    }
                }
                report("Receiving native vtest commands.", finished: false)
            }
        } catch { finish("VTEST FAILED: \(error.localizedDescription)") }
    }
}
