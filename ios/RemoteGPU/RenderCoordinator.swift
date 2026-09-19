import Foundation

// Implement this in the C++/Objective-C++ virglrenderer-ios adapter. The
// adapter owns EGL/ANGLE/IOSurface; it never owns QUIC ordering or pairing.
protocol RemoteGPUVTestRenderer: AnyObject {
    func submitVTest(_ bytes: Data) throws -> [Data]
    func isFenceComplete(for present: RemoteGPUPresent) -> Bool
    func present(_ present: RemoteGPUPresent) throws
}

final class RemoteGPURenderCoordinator {
    private let renderer: RemoteGPUVTestRenderer
    private let order = RemoteGPUFrameOrder()
    private weak var transport: RemoteGPUQUICRenderConnection?
    private var replySequence: UInt64 = 0

    init(renderer: RemoteGPUVTestRenderer, transport: RemoteGPUQUICRenderConnection) {
        self.renderer = renderer
        self.transport = transport
        transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    private func handle(_ event: RemoteGPUConnectionEvent) {
        guard case let .envelope(envelope) = event else { return }
        do {
            switch envelope.type {
            case .vtestBytes:
                try order.consumeVTest(envelope.payload) { [weak self] bytes in
                    guard let self else { return }
                    for reply in try self.renderer.submitVTest(bytes) {
                        self.replySequence += 1
                        self.transport?.sendVTestReply(sequence: self.replySequence, bytes: reply)
                    }
                }
                try drainPresents()
            case .present:
                try order.enqueuePresent(envelope.payload)
                try drainPresents()
            case .error:
                throw RemoteGPUProtocolError.invalidPresent
            case .hello:
                throw RemoteGPUProtocolError.unknownType(RemoteGPUType.hello.rawValue)
            }
        } catch {
            transport?.close()
        }
    }

    private func drainPresents() throws {
        for present in order.readyToPresent(fenceCompleted: renderer.isFenceComplete) {
            try renderer.present(present)
        }
    }
}
