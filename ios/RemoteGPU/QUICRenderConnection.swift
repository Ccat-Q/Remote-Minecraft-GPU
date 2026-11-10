import Foundation
@preconcurrency import Network

enum RemoteGPUConnectionEvent {
    case ready
    case envelope(RemoteGPUEnvelope)
    case failed(Error)
    case closed
}

// One NWConnection is one bidirectional QUIC stream. RemoteGPU intentionally
// keeps vtest data and PRESENT on this stream; opening another stream would
// lose their ordering guarantee.
// Network.framework invokes every callback on `queue`; the object does not
// expose mutable transport state across queues. The explicit conformance lets
// Swift 6 accept the framework's @Sendable callback signatures.
final class RemoteGPUQUICRenderConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.remotegpu.render", qos: .userInteractive)
    private let pairingToken: Data
    private let decoder = RemoteGPUStreamDecoder()
    private var stopped = false // Accessed only on queue.
    private let ingress = RemoteGPUBoundedIngress()
    private let sendBudget = RemoteGPUSendBudget()

    var onEvent: ((RemoteGPUConnectionEvent) -> Void)?
    // Optional constant-space activity sampler; includes incomplete envelopes.
    var onStreamBytes: (() -> Void)?
    // Install before start. Caller MUST complete every delivered batch, even
    // after failure/cancel. Only this optional mode changes receive scheduling.
    var onBatch: (([RemoteGPUEnvelope], @escaping @Sendable () -> Void) -> Void)?

    init(host: String, port: UInt16, pairingToken: String) {
        let options = NWProtocolQUIC.Options(alpn: ["remotegpu/1"])
        options.direction = .bidirectional
        let parameters = NWParameters(quic: options)
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        self.pairingToken = Data(pairingToken.utf8)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.stopped else { return }
                guard self.send(type: .hello, payload: self.pairingToken) else { return }
                self.onEvent?(.ready)
                self.receiveNext()
            case .failed(let error):
                self.fail(error)
            case .cancelled:
                self.sendBudget.cancel()
                self.stopped = true
                self.ingress.cancel()
                self.onEvent?(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        sendBudget.cancel() // Synchronous: no admission while close waits on queue.
        queue.async {
            self.stopped = true
            self.ingress.cancel()
            self.connection.cancel()
        }
    }

    func sendVTestReply(sequence: UInt64, bytes: Data) {
        send(type: .vtestBytes, payload: bytes, sequence: sequence)
    }

    @discardableResult
    private func send(type: RemoteGPUType, payload: Data, sequence: UInt64? = nil) -> Bool {
        // Reserve before either encoding or dispatch. Avoid the intermediate
        // VTestChunk payload copy; only the final wire Data is transport-owned.
        let overhead = sequence == nil ? 10 : 18
        let (wireCount, overflow) = payload.count.addingReportingOverflow(overhead)
        let reservation = sendBudget.reserve(byteCount: overflow ? -1 : wireCount)
        switch reservation {
        case .rejected(let reportFailure):
            if reportFailure {
                queue.async { [weak self] in self?.fail(RemoteGPUProtocolError.payloadTooLarge) }
            }
            return false
        case .granted(let lease):
            let bytes = RemoteGPUSendWire.encode(type: type, payload: payload, sequence: sequence)
            queue.async { [weak self, bytes, lease] in
                guard let self, !self.stopped else { return } // Lease deinit releases dropped work.
                self.connection.send(content: bytes, contentContext: .defaultMessage, isComplete: false,
                    completion: .contentProcessed { [weak self, lease] error in
                        // Network has finished processing the content. No Data is
                        // retained by this callback or its follow-up queue job.
                        let shouldReport = error != nil && (self?.sendBudget.cancel() ?? false)
                        lease.finish()
                        guard let error, shouldReport else { return }
                        self?.queue.async { [weak self] in self?.fail(error) }
                    })
            }
            return true
        }
    }

    // Queue-confined terminal transition; all send/receive errors converge here.
    private func fail(_ error: Error) {
        sendBudget.cancel()
        guard !stopped else { return }
        stopped = true
        ingress.cancel()
        onEvent?(.failed(error))
        connection.cancel()
    }

    private func endStream() {
        sendBudget.cancel()
        guard !stopped else { return }
        stopped = true
        ingress.cancel()
        onEvent?(.closed)
    }

    private func receiveNext() {
        guard !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.fail(error); return }
            guard !self.stopped else { return }
            if let data {
                if !data.isEmpty { self.onStreamBytes?() }
                do {
                    let envelopes = try self.decoder.feed(data)
                    if complete && !self.decoder.atEnvelopeBoundary { throw RemoteGPUProtocolError.invalidVTestChunk }
                    if let consumer = self.onBatch, !envelopes.isEmpty {
                        let ticket = try self.ingress.admit(envelopes)
                        consumer(envelopes) { [weak self] in
                            guard let self else { return }
                            self.queue.async {
                                guard self.ingress.complete(ticket), !self.stopped else { return }
                                if complete { self.endStream() } else { self.receiveNext() }
                            }
                        }
                        return
                    }
                    for envelope in envelopes {
                        guard !self.stopped else { return }
                        self.onEvent?(.envelope(envelope))
                    }
                } catch {
                    self.fail(error)
                    return
                }
            }
            if complete {
                if self.decoder.atEnvelopeBoundary {
                    // Let replies produced synchronously by onEvent enter the
                    // transport queue before closing admission. Asynchronous
                    // consumers must use onBatch's completion contract.
                    self.queue.async { [weak self] in self?.endStream() }
                } else { self.fail(RemoteGPUProtocolError.invalidVTestChunk) }
            } else { self.receiveNext() }
        }
    }
}
