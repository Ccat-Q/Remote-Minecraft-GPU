import XCTest
@testable import RemoteGPUProtocol

final class AsyncDisplaySessionTests: XCTestCase {
    private func present(_ frame: UInt64 = 1, resource: UInt64 = 42) throws -> RemoteGPUPresent {
        var payload = Data()
        for value in [frame, resource, UInt64(1)] {
            var word = value.bigEndian
            withUnsafeBytes(of: &word) { payload.append(contentsOf: $0) }
        }
        for value in [UInt32(0), 0, 0, 0, 64, 64] {
            var word = value.bigEndian
            withUnsafeBytes(of: &word) { payload.append(contentsOf: $0) }
        }
        return try RemoteGPUPresent(payload: payload)
    }
    func testActualTimerTicksWithoutNetworkTraffic() {
        let fired = expectation(description: "independent owner-queue GPU pulses without packets")
        fired.expectedFulfillmentCount = 3
        let driver = RemoteGPUCompletionPulse(queue: DispatchQueue(label: "test.completion")) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
        driver.cancel()
    }
    func testSingleSlotWaitsForAllThreeStagesAndRejectsOvertake() throws {
        let state = RemoteGPUSingleSlotCompletion()
        let first = try present()
        let ticket = try state.begin(first, at: 100)
        XCTAssertThrowsError(try state.begin(present(2), at: 100))
        try state.observe(ticket, stage: .producer, at: 101) // Unsignaled fence, not a completion.
        XCTAssertEqual(state.active, ticket)
        XCTAssertThrowsError(try state.observe(ticket, stage: .metal, at: 101))
        try state.observe(ticket, stage: .copy, at: 102)
        XCTAssertThrowsError(try state.observe(ticket, stage: .producer, at: 103))
        try state.observe(ticket, stage: .metal, at: 104)
        XCTAssertNotNil(state.active)
        try state.observe(ticket, stage: .complete, at: 105)
        XCTAssertNil(state.active)
        XCTAssertEqual(state.polls, 4)
    }
    func testGenerationRejectsOldCallbackEvenWhenResourceIDIsReused() throws {
        let state = RemoteGPUSingleSlotCompletion()
        let old = try state.begin(present(), at: 0)
        try state.observe(old, stage: .copy, at: 1)
        try state.observe(old, stage: .metal, at: 2)
        try state.observe(old, stage: .complete, at: 3)
        let new = try state.begin(present(2, resource: 42), at: 4)
        XCTAssertNotEqual(old.generation, new.generation)
        XCTAssertThrowsError(try state.observe(old, stage: .complete, at: 5))
        XCTAssertEqual(state.active, new)
    }
    func testCancellationAtEveryStageCannotCompleteOrReopen() throws {
        for stage in 1...3 {
            let state = RemoteGPUSingleSlotCompletion()
            let ticket = try state.begin(present(), at: 0)
            if stage >= 2 { try state.observe(ticket, stage: .copy, at: 1) }
            if stage >= 3 { try state.observe(ticket, stage: .metal, at: 2) }
            state.cancel()
            XCTAssertNil(state.active)
            XCTAssertThrowsError(try state.observe(ticket, stage: .complete, at: 3))
            XCTAssertThrowsError(try state.begin(present(2), at: 4))
        }
    }
    func testTimeoutAndClockChecksArePerPhase() throws {
        let state = RemoteGPUSingleSlotCompletion()
        let ticket = try state.begin(present(), at: 100)
        XCTAssertThrowsError(try state.observe(ticket, stage: .producer, at: 99))
        XCTAssertThrowsError(try state.observe(ticket, stage: .copy, at: .infinity))
        try state.observe(ticket, stage: .copy, at: 109)
        try state.observe(ticket, stage: .metal, at: 118)
        XCTAssertThrowsError(try state.observe(ticket, stage: .complete, at: 128))
        XCTAssertNotNil(state.active)
    }
    func testBatchSuffixRetainedUntilFinalFrameCompletionOrCancellation() throws {
        let cursor = RemoteGPUDisplayBatchCursor()
        let before = RemoteGPUVTestChunk(sequence: 1, bytes: Data([1])).envelope
        let marker = RemoteGPUEnvelope(type: .present, flags: 0, payload: try presentPayload())
        let overwrite = RemoteGPUVTestChunk(sequence: 2, bytes: Data([2])).envelope
        var releases = 0
        try cursor.admit([before, marker, overwrite]) { releases += 1 }
        XCTAssertEqual(cursor.next(), before)
        XCTAssertEqual(cursor.next(), marker)
        // Owner returns to run loop here; the real native snapshot barrier is
        // held. No new receive lease or suffix can be admitted by another batch.
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(cursor.remaining, 1)
        XCTAssertThrowsError(try cursor.admit([overwrite]) { XCTFail("Not admitted") })
        XCTAssertEqual(cursor.next(), overwrite) // Only AFTER owner observes completion.
        XCTAssertNil(cursor.next())
        cursor.release(); cursor.release()
        XCTAssertEqual(releases, 1)
        try cursor.admit([marker]) { releases += 1 }
        XCTAssertEqual(cursor.next(), marker)
        XCTAssertEqual(releases, 1) // Final PRESENT has NO following network packet.
        cursor.release() // Cancellation/close also returns the lease exactly once.
        XCTAssertEqual(releases, 2)
    }
    func testAsyncSourceBarrierPreservesStrictOrderThroughMetal() throws {
        let order = RemoteGPUSerialDisplayOrder()
        let state = RemoteGPUSingleSlotCompletion()
        try order.consume(RemoteGPUVTestChunk(sequence: 1, bytes: Data([1])).envelope.payload) { _ in }
        let frame = try order.beginPresent(presentPayload())
        let ticket = try state.begin(frame, at: 0)
        for (stage, time) in [(RemoteGPUCompletionStage.copy, 1.0), (.metal, 2.0)] {
            try state.observe(ticket, stage: stage, at: time)
            XCTAssertThrowsError(try order.consume(RemoteGPUVTestChunk(sequence: 2, bytes: Data([2])).envelope.payload) { _ in
                XCTFail("Source overwrite escaped the single-slot barrier")
            })
        }
        try state.observe(ticket, stage: .complete, at: 3)
        try order.completePresent(frame)
        try order.consume(RemoteGPUVTestChunk(sequence: 2, bytes: Data([2])).envelope.payload) { _ in }
    }
    func testIngressStillRejectsUnboundedBatch() throws {
        let cursor = RemoteGPUDisplayBatchCursor()
        let envelope = RemoteGPUEnvelope(type: .vtestBytes, flags: 0, payload: Data())
        XCTAssertThrowsError(try cursor.admit(Array(repeating: envelope, count: 4097)) { XCTFail() })
        XCTAssertFalse(cursor.isActive)
    }
    private func presentPayload() throws -> Data {
        // Re-encode the fixed test marker, not a renderer/visual fixture.
        let frame = try present()
        var payload = Data()
        for value in [frame.frameID, frame.resourceID, frame.afterSequence] {
            var word = value.bigEndian
            withUnsafeBytes(of: &word) { payload.append(contentsOf: $0) }
        }
        for value in [UInt32(0), 0, 0, 0, 64, 64] {
            var word = value.bigEndian
            withUnsafeBytes(of: &word) { payload.append(contentsOf: $0) }
        }
        return payload
    }
}
