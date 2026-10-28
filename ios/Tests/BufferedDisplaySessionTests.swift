import XCTest
@testable import RemoteGPUProtocol

final class BufferedDisplaySessionTests: XCTestCase {
    private func payload(_ frame: UInt64, after: UInt64 = 1) -> Data {
        var out = Data()
        for value in [frame, UInt64(42), after] {
            var word = value.bigEndian
            withUnsafeBytes(of: &word) { out.append(contentsOf: $0) }
        }
        for value in [UInt32(0), 0, 0, 0, 64, 64] {
            var word = value.bigEndian
            withUnsafeBytes(of: &word) { out.append(contentsOf: $0) }
        }
        return out
    }
    private func ticket(_ frame: UInt64, slot: Int, after: UInt64 = 1) -> RemoteGPUBufferedTicket {
        RemoteGPUBufferedTicket(slot: slot, generation: frame, frame: frame, resource: 42, after: after)
    }
    private func start() throws -> RemoteGPUBufferedDisplayOrder {
        let order = RemoteGPUBufferedDisplayOrder()
        try order.consume(RemoteGPUVTestChunk(sequence: 1, bytes: Data([1])).envelope.payload) { _ in }
        return order
    }
    func testSourceBarrierReleasesAfterCopyNotAfterReceiveOrFenceSubmission() throws {
        let order = try start()
        _ = try order.beginPresent(payload(1))
        let one = ticket(1, slot: 0)
        try order.admitted(one)
        XCTAssertTrue(order.sourceBarrier)
        XCTAssertThrowsError(try order.consume(RemoteGPUVTestChunk(sequence: 2, bytes: Data([2])).envelope.payload) { _ in XCTFail() })
        XCTAssertThrowsError(try order.complete(one)) // Not snapshotted or displayed yet.
        try order.snapshot(one)
        XCTAssertTrue(order.canAdvance)
        XCTAssertEqual(order.displayedFrame, 0) // Still in Metal/ready ownership.
        try order.consume(RemoteGPUVTestChunk(sequence: 2, bytes: Data([2])).envelope.payload) { _ in }
    }
    func testTwoSlotsBackpressureAndInOrderMetalCompletion() throws {
        let order = try start()
        let one = ticket(1, slot: 0), two = ticket(2, slot: 1)
        _ = try order.beginPresent(payload(1)); try order.admitted(one); try order.snapshot(one)
        _ = try order.beginPresent(payload(2)); try order.admitted(two); try order.snapshot(two)
        XCTAssertEqual(order.inUse, 2)
        XCTAssertFalse(order.canAdvance)
        XCTAssertThrowsError(try order.beginPresent(payload(3)))
        XCTAssertThrowsError(try order.complete(two)) // Cannot overtake older display.
        XCTAssertEqual(try order.complete(one).frameID, 1)
        XCTAssertTrue(order.canAdvance)
        _ = try order.beginPresent(payload(3)); try order.admitted(ticket(3, slot: 0))
        XCTAssertThrowsError(try order.snapshot(one)) // Old generation cannot alter new frame.
        XCTAssertEqual(try order.complete(two).frameID, 2)
    }
    func testSlotCannotBeAssignedWhileOlderMetalStillOwnsIt() throws {
        let order = try start()
        _ = try order.beginPresent(payload(1)); try order.admitted(ticket(1, slot: 0)); try order.snapshot(ticket(1, slot: 0))
        _ = try order.beginPresent(payload(2))
        XCTAssertThrowsError(try order.admitted(ticket(2, slot: 0)))
        try order.admitted(ticket(2, slot: 1))
        XCTAssertThrowsError(try order.snapshot(RemoteGPUBufferedTicket(slot: 1, generation: 2, frame: 2, resource: 43, after: 1)))
        try order.snapshot(ticket(2, slot: 1))
    }
    func testCancellationRejectsBothPendingSlotsAndLateEvents() throws {
        let order = try start()
        for frame in UInt64(1)...2 {
            _ = try order.beginPresent(payload(frame))
            let lease = ticket(frame, slot: Int(frame - 1))
            try order.admitted(lease); try order.snapshot(lease)
        }
        order.cancel()
        XCTAssertFalse(order.canAdvance)
        for frame in UInt64(1)...2 {
            XCTAssertThrowsError(try order.complete(ticket(frame, slot: Int(frame - 1))))
        }
        XCTAssertThrowsError(try order.beginPresent(payload(3)))
    }
    func testSequenceAnd16FrameBoundRemainStrict() throws {
        let order = try start()
        XCTAssertThrowsError(try order.beginPresent(payload(1, after: 2)))
        XCTAssertThrowsError(try order.beginPresent(payload(2)))
        for frame in UInt64(1)...16 {
            _ = try order.beginPresent(payload(frame))
            let lease = ticket(frame, slot: Int((frame - 1) % 2))
            try order.admitted(lease); try order.snapshot(lease); _ = try order.complete(lease)
        }
        XCTAssertThrowsError(try order.beginPresent(payload(17)))
        XCTAssertEqual(order.inUse, 0)
    }
}
