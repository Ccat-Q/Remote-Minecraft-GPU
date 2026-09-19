import Foundation
import Network

enum RemoteGPUConnectionEvent {
    case ready
    case envelope(RemoteGPUEnvelope)
    case failed(Error)
    case closed
}

// One NWConnection is one bidirectional QUIC stream. RemoteGPU intentionally
// keeps vtest data and PRESENT on this stream; opening another stream would
// lose their ordering guarantee.
final class RemoteGPUQUICRenderConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.remotegpu.render", qos: .userInteractive)
    private let pairingToken: Data
    private let decoder = RemoteGPUStreamDecoder()

    var onEvent: ((RemoteGPUConnectionEvent) -> Void)?

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

    func close() { connection.cancel() }

    func sendVTestReply(sequence: UInt64, bytes: Data) {
        send(RemoteGPUVTestChunk(sequence: sequence, bytes: bytes).envelope)
    }

    private func send(_ envelope: RemoteGPUEnvelope) {
        connection.send(content: envelope.encoded(), contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [weak self] error in
            if let error { self?.onEvent?(.failed(error)) }
        })
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.onEvent?(.failed(error)); return }
            if let data {
                do {
                    for envelope in try self.decoder.feed(data) {
                        self.onEvent?(.envelope(envelope))
                    }
                } catch {
                    self.onEvent?(.failed(error))
                    self.connection.cancel()
                    return
                }
            }
            if complete { self.onEvent?(.closed) } else { self.receiveNext() }
        }
    }
}
