import Foundation

// Coalesce partial-stream activity without enqueueing one renderer task per
// network receive. Tiny fragments must not create an unbounded callback queue.
final class RemoteGPUStreamActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval?
    func record(at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = max(value ?? time, time)
    }
    var latest: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// Local monotonic evidence only. Completion means native GPU copy AND Metal
// completion returned; it never asserts that the human saw the right pixels.
final class RemoteGPUDisplayEvidence {
    let sessionID: String
    let startedAt: TimeInterval
    private(set) var completedCount = 0
    private(set) var lastPresent: UInt64 = 0
    private var lastCompletion: TimeInterval?
    private var lastVTest: TimeInterval?

    init(sessionID: String, startedAt: TimeInterval) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
    func receivedVTest(at time: TimeInterval) { lastVTest = max(lastVTest ?? time, time) }

    func completed(_ present: RemoteGPUPresent, began: TimeInterval, ended: TimeInterval) throws -> String {
        guard completedCount < 16, present.frameID == lastPresent + 1,
            began.isFinite, ended.isFinite, began >= startedAt, ended >= began,
            ended >= (lastCompletion ?? startedAt) else { throw RemoteGPUProtocolError.invalidPresent }
        completedCount += 1
        lastPresent = present.frameID
        lastCompletion = ended
        return String(format: "A21_FRAME present=%llu resource=%llu after=%llu completed_ms=%.3f duration_ms=%.3f",
            present.frameID, present.resourceID, present.afterSequence,
            (ended - startedAt) * 1000, (ended - began) * 1000)
    }
    func quietSeconds(at time: TimeInterval) -> TimeInterval {
        guard let completion = lastCompletion else { return 0 }
        return max(0, time - max(completion, lastVTest ?? completion))
    }
    func holdLine(at time: TimeInterval, live: Bool) -> String {
        // Never round 119.9996 up to an apparent 120-second observation.
        let seconds = (quietSeconds(at: time) * 1000).rounded(.down) / 1000
        return String(format: "A21_HOLD live=%@ last_present=%llu quiet_s=%.3f completed=%d visual_confirmation=USER_REQUIRED",
            live ? "YES" : "NO", lastPresent, seconds, completedCount)
    }
}
