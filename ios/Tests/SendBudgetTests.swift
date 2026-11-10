import Foundation
import Dispatch
import XCTest
@testable import RemoteGPUProtocol

final class SendBudgetTests: XCTestCase {
    private enum FixtureError: Error { case rejected }

    private func lease(_ budget: RemoteGPUSendBudget, _ bytes: Int,
                       file: StaticString = #filePath, line: UInt = #line) throws -> RemoteGPUSendBudget.Lease {
        switch budget.reserve(byteCount: bytes) {
        case .granted(let lease): return lease
        case .rejected:
            XCTFail("Expected reservation of \(bytes) bytes", file: file, line: line)
            throw FixtureError.rejected
        }
    }

    private func rejected(_ budget: RemoteGPUSendBudget, _ bytes: Int, report: Bool,
                          file: StaticString = #filePath, line: UInt = #line) {
        switch budget.reserve(byteCount: bytes) {
        case .granted(let lease):
            lease.finish()
            XCTFail("Unexpected admission after rejection/close", file: file, line: line)
        case .rejected(let reportFailure):
            XCTAssertEqual(reportFailure, report, file: file, line: line)
        }
    }

    // Model ownership, not a second accounting implementation: both closures
    // retain the SAME production Lease, just as queued work and NW completion do.
    private func retaining(_ lease: RemoteGPUSendBudget.Lease) -> () -> Void {
        { [lease] in withExtendedLifetime(lease) {} }
    }

    func testQueuedAndInflightShareOneExactWireBudget() throws {
        let budget = RemoteGPUSendBudget(limit: 64)
        let queued = try lease(budget, 18) // Empty vtest reply still has wire overhead.
        let inflight = try lease(budget, 46)
        XCTAssertEqual(budget.reservedBytes, 64)
        queued.finish()
        XCTAssertEqual(budget.reservedBytes, 46)
        let replacement = try lease(budget, 18)
        XCTAssertEqual(budget.reservedBytes, 64)
        inflight.finish()
        replacement.finish()
        XCTAssertEqual(budget.reservedBytes, 0)
    }

    func testOverLimitClosesOnceWithoutForgivingOutstandingBytes() throws {
        let budget = RemoteGPUSendBudget(limit: 32)
        let queued = try lease(budget, 12)
        let inflight = try lease(budget, 20)
        rejected(budget, 1, report: true)
        XCTAssertEqual(budget.reservedBytes, 32)
        rejected(budget, 1, report: false)
        queued.finish()
        XCTAssertEqual(budget.reservedBytes, 20)
        // Credit returned after failure never reopens the session.
        rejected(budget, 1, report: false)
        inflight.finish()
        XCTAssertEqual(budget.reservedBytes, 0)
        rejected(budget, 0, report: false)
    }

    func testCancelKeepsBothQueuedAndInflightOwnersCharged() throws {
        let budget = RemoteGPUSendBudget(limit: 64)
        var queuedOwner: (() -> Void)? = retaining(try lease(budget, 24))
        var networkOwner: (() -> Void)? = retaining(try lease(budget, 40))
        XCTAssertEqual(budget.reservedBytes, 64)
        budget.cancel()
        budget.cancel()
        XCTAssertEqual(budget.reservedBytes, 64)
        XCTAssertEqual(budget.reservedItems, 2)
        rejected(budget, 1, report: false)
        queuedOwner?()
        networkOwner?()
        queuedOwner = nil // Discard queued closure only when it actually dies.
        XCTAssertEqual(budget.reservedBytes, 40)
        XCTAssertEqual(budget.reservedItems, 1)
        networkOwner = nil // Simulate final NW ownership ending, without callback.
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertEqual(budget.reservedItems, 0)
        rejected(budget, 1, report: false)
    }

    func testLastOwnerRatherThanFirstOwnerDeinitReleasesCredit() throws {
        let budget = RemoteGPUSendBudget(limit: 18)
        var queueOwner: (() -> Void)?
        var completionOwner: (() -> Void)?
        do {
            let shared = try lease(budget, 18)
            queueOwner = retaining(shared)
            completionOwner = retaining(shared)
        }
        budget.cancel()
        queueOwner?()
        completionOwner?()
        queueOwner = nil
        XCTAssertEqual(budget.reservedBytes, 18)
        completionOwner = nil
        XCTAssertEqual(budget.reservedBytes, 0)
    }

    func testFinishAndLateDuplicateCompletionCannotReleaseAnotherLease() throws {
        let budget = RemoteGPUSendBudget(limit: 64)
        var completed: RemoteGPUSendBudget.Lease? = try lease(budget, 32)
        completed?.finish()
        XCTAssertEqual(budget.reservedBytes, 0)
        let current = try lease(budget, 64)
        completed?.finish() // Late callback from old send must not free new credit.
        XCTAssertEqual(budget.reservedBytes, 64)
        completed = nil // deinit after finish is also idempotent.
        XCTAssertEqual(budget.reservedBytes, 64)
        budget.cancel()
        current.finish()
        current.finish()
        XCTAssertEqual(budget.reservedBytes, 0)
    }

    func testDroppingUnsubmittedLeaseRollsBackWithoutClosingBudget() throws {
        let budget = RemoteGPUSendBudget(limit: 32)
        var abandoned: RemoteGPUSendBudget.Lease? = try lease(budget, 32)
        withExtendedLifetime(abandoned) { XCTAssertEqual(budget.reservedBytes, 32) }
        abandoned = nil // Encoding/enqueue early-exit ownership rollback.
        XCTAssertEqual(budget.reservedBytes, 0)
        let next = try lease(budget, 32)
        next.finish()
        XCTAssertEqual(budget.reservedBytes, 0)
    }

    func testZeroAndNegativeSizesHaveExplicitSafeSemantics() throws {
        let budget = RemoteGPUSendBudget(limit: 32)
        let empty = try lease(budget, 0)
        XCTAssertEqual(budget.reservedBytes, 0)
        empty.finish()
        rejected(budget, -1, report: true)
        XCTAssertEqual(budget.reservedBytes, 0)
        rejected(budget, 1, report: false)
    }

    func testHugeCountsAndAdditionOverflowRejectWithoutTrapping() throws {
        let small = RemoteGPUSendBudget(limit: 32)
        rejected(small, Int.max, report: true)
        XCTAssertEqual(small.reservedBytes, 0)
        let huge = RemoteGPUSendBudget(limit: Int.max)
        // This is accounting only: never allocate Int.max bytes of Data.
        let almostAll = try lease(huge, Int.max - 1)
        XCTAssertEqual(huge.reservedBytes, Int.max - 1)
        rejected(huge, 2, report: true)
        XCTAssertEqual(huge.reservedBytes, Int.max - 1)
        almostAll.finish()
        XCTAssertEqual(huge.reservedBytes, 0)
    }

    func testProductionWireMatchesLegacyEnvelopeByteForByte() throws {
        let payloads = [Data(), Data([0, 1, 127, 128, 255]), Data(repeating: 0xa5, count: 128 * 1024)]
        for payload in payloads {
            for sequence in [UInt64(0), 1, 0x0102030405060708, UInt64.max] {
                let expected = RemoteGPUVTestChunk(sequence: sequence, bytes: payload).envelope.encoded()
                let budget = RemoteGPUSendBudget(limit: expected.count)
                let credit = try lease(budget, 18 + payload.count)
                let wire = RemoteGPUSendWire.encode(type: .vtestBytes, payload: payload, sequence: sequence)
                XCTAssertEqual(wire, expected)
                XCTAssertEqual(wire.count, budget.reservedBytes)
                credit.finish()
            }
            let expectedHello = RemoteGPUEnvelope(type: .hello, flags: 0, payload: payload).encoded()
            let budget = RemoteGPUSendBudget(limit: expectedHello.count)
            let credit = try lease(budget, 10 + payload.count)
            XCTAssertEqual(RemoteGPUSendWire.encode(type: .hello, payload: payload), expectedHello)
            credit.finish()
        }
    }

    func testItemLimitRejectsEvenWhenByteBudgetIsNotFull() throws {
        let budget = RemoteGPUSendBudget(limit: 1024, itemLimit: 2)
        let first = try lease(budget, 18)
        let second = try lease(budget, 18)
        XCTAssertEqual(budget.reservedBytes, 36)
        XCTAssertEqual(budget.reservedItems, 2)
        rejected(budget, 18, report: true)
        XCTAssertEqual(budget.reservedItems, 2)
        first.finish()
        first.finish()
        XCTAssertEqual(budget.reservedBytes, 18)
        XCTAssertEqual(budget.reservedItems, 1)
        second.finish()
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertEqual(budget.reservedItems, 0)
        rejected(budget, 18, report: false)
    }

    func testZeroByteLeasesStillConsumeItemsAndCancelDoesNotForgiveThem() throws {
        let budget = RemoteGPUSendBudget(limit: 0, itemLimit: 2)
        var first: RemoteGPUSendBudget.Lease? = try lease(budget, 0)
        var second: RemoteGPUSendBudget.Lease? = try lease(budget, 0)
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertEqual(budget.reservedItems, 2)
        rejected(budget, 0, report: true)
        budget.cancel()
        XCTAssertEqual(budget.reservedItems, 2)
        first?.finish()
        first?.finish()
        first = nil
        XCTAssertEqual(budget.reservedItems, 1)
        withExtendedLifetime(second) { XCTAssertEqual(budget.reservedItems, 1) }
        second = nil
        XCTAssertEqual(budget.reservedItems, 0)
        rejected(budget, 0, report: false)
    }

    func testConcurrentEmptyReservationsCannotBypassItemLimit() {
        let budget = RemoteGPUSendBudget(limit: 1024, itemLimit: 8)
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 256) { _ in
            results.append(budget.reserve(byteCount: 0))
        }
        let result = results.snapshot()
        XCTAssertEqual(result.leases.count, 8)
        XCTAssertEqual(result.rejections, 248)
        XCTAssertEqual(result.reports, 1)
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertEqual(budget.reservedItems, 8)
        guard !result.leases.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            result.leases[index % result.leases.count].finish()
        }
        XCTAssertEqual(budget.reservedItems, 0)
        XCTAssertEqual(budget.reservedBytes, 0)
    }

    // Dispatch captures only Sendable references; mutable test results live
    // behind this lock rather than captured Swift 6 local variables.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var leases: [RemoteGPUSendBudget.Lease] = []
        private var reports = 0
        private var rejections = 0

        func append(_ reservation: RemoteGPUSendBudget.Reservation) {
            lock.lock()
            defer { lock.unlock() }
            switch reservation {
            case .granted(let lease): leases.append(lease)
            case .rejected(let reportFailure):
                rejections += 1
                if reportFailure { reports += 1 }
            }
        }

        func snapshot() -> (leases: [RemoteGPUSendBudget.Lease], reports: Int, rejections: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (leases, reports, rejections)
        }
    }

    func testConcurrentAdmissionBoundsQueuedBytesAndReportsFailureOnce() {
        let budget = RemoteGPUSendBudget(limit: 64)
        let results = Results()
        // Do not finish until all producers have reserved: this simulates a
        // frozen transport queue with many simultaneous native reply producers.
        DispatchQueue.concurrentPerform(iterations: 256) { _ in
            results.append(budget.reserve(byteCount: 8))
        }
        let result = results.snapshot()
        XCTAssertEqual(result.leases.count, 8)
        XCTAssertEqual(result.rejections, 248)
        XCTAssertEqual(result.reports, 1)
        XCTAssertEqual(budget.reservedBytes, 64)
        guard !result.leases.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            // Several completion paths race on each lease.
            result.leases[index % result.leases.count].finish()
        }
        XCTAssertEqual(budget.reservedBytes, 0)
        rejected(budget, 8, report: false)
    }

    func testConcurrentCancelAndLateFinishesKeepOutstandingOwnersCharged() throws {
        let budget = RemoteGPUSendBudget(limit: 128)
        let leases = try (0..<16).map { _ in try lease(budget, 8) }
        DispatchQueue.concurrentPerform(iterations: 128) { _ in budget.cancel() }
        XCTAssertEqual(budget.reservedBytes, 128)
        XCTAssertEqual(budget.reservedItems, 16)
        let rejectedCalls = Results()
        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            rejectedCalls.append(budget.reserve(byteCount: 1))
        }
        XCTAssertEqual(rejectedCalls.snapshot().reports, 0)
        XCTAssertEqual(rejectedCalls.snapshot().rejections, 128)
        XCTAssertEqual(budget.reservedBytes, 128)
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            leases[index % leases.count].finish()
        }
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertEqual(budget.reservedItems, 0)
    }
}
