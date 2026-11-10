import Foundation

// Final-wire encoder shared by production admission and wire-equivalence tests.
// The caller reserves 10 + payload.count (+8 for sequence) before invoking it.
enum RemoteGPUSendWire {
    static func encode(type: RemoteGPUType, payload: Data, sequence: UInt64? = nil) -> Data {
        let payloadCount = payload.count + (sequence == nil ? 0 : 8)
        precondition(payloadCount <= 16 << 20)
        var wire = Data(capacity: 10 + payloadCount)
        wire.append(contentsOf: [0x52, 0x47, 0x50, 0x31, type.rawValue, 0])
        var length = UInt32(payloadCount).bigEndian
        withUnsafeBytes(of: &length) { wire.append(contentsOf: $0) }
        if let sequence {
            var value = sequence.bigEndian
            withUnsafeBytes(of: &value) { wire.append(contentsOf: $0) }
        }
        wire.append(payload)
        return wire
    }
}

// Bounds admitted wire bytes across encoding, queued work and in-flight sends.
// This is not a total-RSS limit: caller buffers and Network.framework's internal
// copies are outside this budget. No callbacks or dispatch occur under its lock.
final class RemoteGPUSendBudget: @unchecked Sendable {
    enum Reservation {
        case granted(Lease)
        case rejected(reportFailure: Bool)
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: RemoteGPUSendBudget?
        private let byteCount: Int

        fileprivate init(owner: RemoteGPUSendBudget, byteCount: Int) {
            self.owner = owner
            self.byteCount = byteCount
        }

        func finish() {
            lock.lock()
            let budget = owner
            owner = nil
            lock.unlock()
            budget?.release(byteCount)
        }

        deinit { finish() }
    }

    private let lock = NSLock()
    private let limit: Int
    private let itemLimit: Int
    private var used = 0
    private var items = 0
    private var closed = false

    init(limit: Int = 2 << 20, itemLimit: Int = 4096) {
        precondition(limit >= 0 && itemLimit >= 0)
        self.limit = limit
        self.itemLimit = itemLimit
    }

    var reservedItems: Int {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var reservedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return used
    }

    func reserve(byteCount: Int) -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return .rejected(reportFailure: false) }
        // Subtraction avoids overflow even for adversarial Int.max requests.
        guard byteCount >= 0, byteCount <= limit - used, items < itemLimit else {
            closed = true
            return .rejected(reportFailure: true)
        }
        used += byteCount
        items += 1
        return .granted(Lease(owner: self, byteCount: byteCount))
    }

    // Closing admission never releases credits owned by still-live sends.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        let wasOpen = !closed
        closed = true
        lock.unlock()
        return wasOpen
    }

    private func release(_ byteCount: Int) {
        lock.lock()
        used -= byteCount
        items -= 1
        lock.unlock()
    }
}
