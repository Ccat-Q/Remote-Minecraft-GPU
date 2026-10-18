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
    private var pendingSendBytes = 0 // Queue-confined, including native replies.

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
                self.send(RemoteGPUEnvelope(type: .hello, flags: 0, payload: self.pairingToken))
                self.onEvent?(.ready)
                self.receiveNext()
            case .failed(let error):
                self.onEvent?(.failed(error))
            case .cancelled:
                self.onEvent?(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        queue.async {
            self.stopped = true
            self.ingress.cancel()
            self.connection.cancel()
        }
    }

    func sendVTestReply(sequence: UInt64, bytes: Data) {
        send(RemoteGPUVTestChunk(sequence: sequence, bytes: bytes).envelope)
    }

    private func send(_ envelope: RemoteGPUEnvelope) {
        let bytes = envelope.encoded()
        queue.async {
            guard !self.stopped else { return }
            guard self.pendingSendBytes + bytes.count <= 2 << 20 else {
                self.stopped = true; self.ingress.cancel()
                self.onEvent?(.failed(RemoteGPUProtocolError.payloadTooLarge))
                self.connection.cancel()
                return
            }
            self.pendingSendBytes += bytes.count
            self.connection.send(content: bytes, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        self.pendingSendBytes -= bytes.count
                        if let error, !self.stopped {
                            self.stopped = true; self.ingress.cancel()
                            self.onEvent?(.failed(error)); self.connection.cancel()
                        }
                    }
                })
        }
    }

    private func receiveNext() {
        guard !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.onEvent?(.failed(error)); return }
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
                                if complete { self.onEvent?(.closed) } else { self.receiveNext() }
                            }
                        }
                        return
                    }
                    for envelope in envelopes {
                        guard !self.stopped else { return }
                        self.onEvent?(.envelope(envelope))
                    }
                } catch {
                    self.stopped = true
                    self.ingress.cancel()
                    self.onEvent?(.failed(error))
                    self.connection.cancel()
                    return
                }
            }
            if complete {
                if self.decoder.atEnvelopeBoundary { self.onEvent?(.closed) }
                else { self.onEvent?(.failed(RemoteGPUProtocolError.invalidVTestChunk)); self.connection.cancel() }
            } else { self.receiveNext() }
        }
    }
}
