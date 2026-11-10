import Foundation
import XCTest
@testable import RemoteGPUProtocol

final class SessionRetirementTests: XCTestCase {
    func testSuccessfulRetirementIsTheOnlyReconnectPath() throws {
        let owner = RemoteGPUSessionRetirement()
        XCTAssertNil(owner.snapshot)
        let token = try XCTUnwrap(owner.acquire())
        XCTAssertEqual(owner.snapshot?.phase, .running)
        XCTAssertEqual(owner.snapshot?.acceptsWork, true)
        XCTAssertNil(owner.acquire())
        XCTAssertFalse(owner.complete(token, success: true))
        XCTAssertTrue(owner.requestStop(token))
        XCTAssertFalse(owner.requestStop(token))
        XCTAssertEqual(owner.snapshot?.acceptsWork, false)
        XCTAssertNil(owner.acquire())
        XCTAssertTrue(owner.markRetiring(token))
        XCTAssertFalse(owner.markRetiring(token))
        XCTAssertEqual(owner.snapshot?.phase, .retiring)
        XCTAssertNil(owner.acquire())
        XCTAssertTrue(owner.complete(token, success: true))
        XCTAssertEqual(owner.snapshot?.phase, .retired)
        XCTAssertEqual(owner.snapshot?.allowsReconnect, true)
        XCTAssertFalse(owner.complete(token, success: true))
        let replacement = try XCTUnwrap(owner.acquire())
        XCTAssertNotEqual(token, replacement)
    }

    func testCleanupFailurePermanentlyRetainsOwner() throws {
        let owner = RemoteGPUSessionRetirement()
        let token = try XCTUnwrap(owner.acquire())
        XCTAssertTrue(owner.markRetiring(token))
        XCTAssertTrue(owner.complete(token, success: false))
        XCTAssertEqual(owner.snapshot?.phase, .quarantined)
        XCTAssertEqual(owner.snapshot?.acceptsWork, false)
        XCTAssertEqual(owner.snapshot?.allowsReconnect, false)
        XCTAssertNil(owner.acquire())
        XCTAssertFalse(owner.complete(token, success: false))
        XCTAssertFalse(owner.requestStop(token))
        XCTAssertFalse(owner.markRetiring(token))
        XCTAssertFalse(owner.timeout(token))
        XCTAssertNil(owner.acquire())
        XCTAssertEqual(owner.snapshot?.quarantineReason, .cleanupFailed)
        let failure = owner.snapshot
        XCTAssertFalse(owner.complete(token, success: true))
        XCTAssertNil(owner.acquire())
        XCTAssertEqual(owner.snapshot, failure)
    }

    func testWatchdogDoesNotForceReclaimAndLateSuccessIsGenerationChecked() throws {
        for retireBeforeTimeout in [false, true] {
            let owner = RemoteGPUSessionRetirement()
            let token = try XCTUnwrap(owner.acquire())
            XCTAssertTrue(owner.requestStop(token))
            if retireBeforeTimeout { XCTAssertTrue(owner.markRetiring(token)) }
            XCTAssertTrue(owner.timeout(token))
            XCTAssertEqual(owner.snapshot?.phase, .quarantined)
            for _ in 0..<20 {
                XCTAssertFalse(owner.timeout(token))
                XCTAssertNil(owner.acquire())
            }
            XCTAssertTrue(owner.complete(token, success: true))
            let next = try XCTUnwrap(owner.acquire())
            let before = owner.snapshot
            XCTAssertFalse(owner.requestStop(token))
            XCTAssertFalse(owner.markRetiring(token))
            XCTAssertFalse(owner.timeout(token))
            XCTAssertFalse(owner.complete(token, success: false))
            XCTAssertFalse(owner.complete(token, success: true))
            XCTAssertEqual(owner.snapshot, before)
            XCTAssertEqual(owner.snapshot?.token, next)
        }
    }

    func testUnownedCallbacksAndRunningTimeoutCannotReleaseOwner() throws {
        let owner = RemoteGPUSessionRetirement()
        let foreign = UUID()
        XCTAssertFalse(owner.requestStop(foreign))
        XCTAssertFalse(owner.markRetiring(foreign))
        XCTAssertFalse(owner.timeout(foreign))
        XCTAssertFalse(owner.complete(foreign, success: true))
        let token = try XCTUnwrap(owner.acquire())
        XCTAssertFalse(owner.timeout(token))
        XCTAssertFalse(owner.complete(token, success: false))
        XCTAssertFalse(owner.complete(foreign, success: true))
        XCTAssertEqual(owner.snapshot?.phase, .running)
        XCTAssertNil(owner.acquire())
        XCTAssertTrue(owner.requestStop(token))
        XCTAssertFalse(owner.complete(token, success: true))
        XCTAssertNil(owner.acquire())
    }

    func testRevisionsIncreaseOnlyForAcceptedTransitions() throws {
        let owner = RemoteGPUSessionRetirement()
        let token = try XCTUnwrap(owner.acquire())
        XCTAssertEqual(owner.snapshot?.revision, 1)
        XCTAssertTrue(owner.requestStop(token))
        XCTAssertEqual(owner.snapshot?.revision, 2)
        XCTAssertFalse(owner.requestStop(token))
        XCTAssertEqual(owner.snapshot?.revision, 2)
        XCTAssertTrue(owner.markRetiring(token))
        XCTAssertEqual(owner.snapshot?.revision, 3)
        XCTAssertTrue(owner.timeout(token))
        XCTAssertEqual(owner.snapshot?.revision, 4)
        XCTAssertEqual(owner.snapshot?.quarantineReason, .timeout)
        XCTAssertTrue(owner.complete(token, success: true))
        XCTAssertEqual(owner.snapshot?.revision, 5)
        XCTAssertNil(owner.snapshot?.quarantineReason)
        let next = try XCTUnwrap(owner.acquire())
        XCTAssertEqual(owner.snapshot?.revision, 6)
        XCTAssertFalse(owner.complete(token, success: true))
        XCTAssertEqual(owner.snapshot?.revision, 6)
        XCTAssertEqual(owner.snapshot?.token, next)
    }

    func testExplicitFailureAfterWatchdogCannotBeOverriddenBySuccess() throws {
        let owner = RemoteGPUSessionRetirement()
        let token = try XCTUnwrap(owner.acquire())
        XCTAssertTrue(owner.markRetiring(token))
        XCTAssertTrue(owner.timeout(token))
        XCTAssertEqual(owner.snapshot?.quarantineReason, .timeout)
        XCTAssertTrue(owner.complete(token, success: false))
        XCTAssertEqual(owner.snapshot?.quarantineReason, .cleanupFailed)
        let failure = owner.snapshot
        XCTAssertFalse(owner.complete(token, success: true))
        XCTAssertFalse(owner.timeout(token))
        XCTAssertNil(owner.acquire())
        XCTAssertEqual(owner.snapshot, failure)
    }

    func testBlockedQueueAdmitsOnlyOneFinishIndependentOfStopRequest() throws {
        let owner = RemoteGPUSessionRetirement()
        let token = try XCTUnwrap(owner.acquire())
        // A network terminal event can request retirement before stop schedules
        // finish. That first retirement request must not consume finish admission.
        XCTAssertTrue(owner.requestStop(token))
        let admission = RemoteGPUFinishAdmission()
        let queue = DispatchQueue(label: "org.remotegpu.test.blocked-finish")
        let finished = expectation(description: "single admitted finish runs")
        queue.suspend() // Deterministic stand-in for an owner queue stuck in GL.
        var admitted = 0
        for _ in 0..<1000 {
            if admission.scheduleOnce() {
                admitted += 1
                queue.async { finished.fulfill() }
            }
        }
        let quarantined = owner.timeout(token)
        let admittedAfterTimeout = admission.scheduleOnce()
        queue.resume()
        XCTAssertEqual(admitted, 1)
        XCTAssertTrue(quarantined)
        XCTAssertFalse(admittedAfterTimeout)
        XCTAssertNil(owner.acquire())
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(admission.scheduleOnce()) // Completion cannot reopen it.
        XCTAssertEqual(owner.snapshot?.phase, .quarantined)
    }

    func testConcurrentStopAndTerminalEventsShareOneFinishAdmission() {
        let admission = RemoteGPUFinishAdmission()
        let winners = Tokens()
        DispatchQueue.concurrentPerform(iterations: 256) { _ in
            if admission.scheduleOnce() { winners.append(UUID()) }
        }
        XCTAssertEqual(winners.snapshot.count, 1)
        XCTAssertFalse(admission.scheduleOnce())
        // A replacement session needs a new gate, never a reset of the old one.
        XCTAssertTrue(RemoteGPUFinishAdmission().scheduleOnce())
        XCTAssertFalse(admission.scheduleOnce())
    }

    private final class Tokens: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID] = []
        func append(_ token: UUID) {
            lock.lock()
            values.append(token)
            lock.unlock()
        }
        var snapshot: [UUID] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testConcurrentAcquisitionAndLateCompletionNeverOverlapOwners() throws {
        let owner = RemoteGPUSessionRetirement()
        let winners = Tokens()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if let token = owner.acquire() { winners.append(token) }
        }
        XCTAssertEqual(winners.snapshot.count, 1)
        let token = try XCTUnwrap(winners.snapshot.first)
        XCTAssertTrue(owner.markRetiring(token))
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            owner.timeout(token)
        }
        XCTAssertEqual(owner.snapshot?.phase, .quarantined)
        XCTAssertNil(owner.acquire())
        XCTAssertTrue(owner.complete(token, success: true))
        let next = try XCTUnwrap(owner.acquire())
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            owner.complete(token, success: true)
            owner.timeout(token)
            if let acquired = owner.acquire() { winners.append(acquired) }
        }
        XCTAssertEqual(winners.snapshot.count, 1)
        XCTAssertEqual(owner.snapshot?.token, next)
        XCTAssertEqual(owner.snapshot?.phase, .running)
    }
}
