import Foundation

// One gate per session, independent of cancellation/retirement state. Winning
// admission permits exactly one finish job; it does not execute or dispatch it.
// Never reset the gate when finish returns or a watchdog times out.
final class RemoteGPUFinishAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    func scheduleOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }
}

// Safe Remote entry points share this process owner. Legacy diagnostics run
// only in the separately selected, restart-required process mode and do not
// claim this model's retirement guarantee.
// This model never waits for a GPU, dispatches work, invokes callbacks or calls GL.
// A watchdog only quarantines; it cannot prove that native teardown finished.
final class RemoteGPUSessionRetirement: @unchecked Sendable {
    static let shared = RemoteGPUSessionRetirement()

    typealias Token = UUID

    enum Phase: String, Equatable, Sendable {
        case running, stopRequested, retiring, quarantined, retired
    }

    enum QuarantineReason: String, Equatable, Sendable {
        case timeout, cleanupFailed
    }

    struct Snapshot: Equatable, Sendable {
        let token: Token
        let phase: Phase
        let revision: UInt64
        var quarantineReason: QuarantineReason? = nil
        var acceptsWork: Bool { phase == .running }
        var allowsReconnect: Bool { phase == .retired }
    }

    private let lock = NSLock()
    private var state: Snapshot?
    private var revision: UInt64 = 0

    // Called only under lock. Fail closed instead of wrapping a UI revision.
    private func transition(_ token: Token, to phase: Phase,
                            reason: QuarantineReason? = nil) -> Bool {
        guard revision < UInt64.max else { return false }
        revision += 1
        state = Snapshot(token: token, phase: phase, revision: revision, quarantineReason: reason)
        return true
    }

    // Separate instances are useful for isolated tests. Production must use
    // shared: independent instances cannot arbitrate process-global virgl state.
    init() {}

    var snapshot: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func acquire() -> Token? {
        lock.lock()
        defer { lock.unlock() }
        guard state == nil || state?.phase == .retired else { return nil }
        let token = UUID()
        guard transition(token, to: .running) else { return nil }
        return token
    }

    @discardableResult
    func requestStop(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = state, current.token == token, current.phase == .running else { return false }
        return transition(token, to: .stopRequested)
    }

    @discardableResult
    func markRetiring(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = state, current.token == token,
              current.phase == .running || current.phase == .stopRequested else { return false }
        return transition(token, to: .retiring)
    }

    @discardableResult
    func timeout(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = state, current.token == token,
              current.phase == .stopRequested || current.phase == .retiring else { return false }
        return transition(token, to: .quarantined, reason: .timeout)
    }

    // The caller may pass success only after actual native cleanup confirmation,
    // never for a timeout, cancellation request, returned report or lost wrapper.
    // A late genuine success can release only a watchdog timeout quarantine.
    // Explicit cleanup failure is terminal for this owner; retrying complete
    // cannot certify resource safety or permit a new process-global renderer.
    @discardableResult
    func complete(_ token: Token, success: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = state, current.token == token,
              current.phase == .retiring || current.phase == .quarantined else { return false }
        guard current.quarantineReason != .cleanupFailed else { return false }
        return transition(token, to: success ? .retired : .quarantined,
                          reason: success ? nil : .cleanupFailed)
    }
}
