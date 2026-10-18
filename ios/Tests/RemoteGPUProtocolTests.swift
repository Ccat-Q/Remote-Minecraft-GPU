import XCTest
@testable import RemoteGPUProtocol

final class RemoteGPUProtocolTests: XCTestCase {
    func testFragmentedEnvelope() throws {
        let source = RemoteGPUEnvelope(type: .vtestBytes, flags: 0, payload: Data([0, 0, 0, 1, 1]))
        let wire = source.encoded()
        let decoder = RemoteGPUStreamDecoder()
        XCTAssertEqual(try decoder.feed(wire.prefix(4)), [])
        let envelopes = try decoder.feed(wire.dropFirst(4))
        XCTAssertEqual(envelopes.count, 1)
        XCTAssertEqual(envelopes[0].payload, source.payload)
    }

    func testFrameOrderRejectsGap() throws {
        let order = RemoteGPUFrameOrder()
        var chunk = Data(repeating: 0, count: 8)
        chunk[7] = 2
        XCTAssertThrowsError(try order.consumeVTest(chunk, submit: { _ in }))
    }

    private func present(frame: UInt64, after: UInt64) -> Data {
        var bytes = Data()
        for value in [frame, UInt64(42), after] {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        }
        for value in [UInt32(0), 0, 0, 0, 64, 64] {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    func testPresentationRequiresConsumedCommandsAndFence() throws {
        let order = RemoteGPUFrameOrder()
        try order.enqueuePresent(present(frame: 1, after: 1))
        XCTAssertTrue(order.readyToPresent(fenceCompleted: { _ in true }).isEmpty)
        let chunk = RemoteGPUVTestChunk(sequence: 1, bytes: Data([0xaa]))
        var submitted = Data()
        try order.consumeVTest(chunk.envelope.payload) { submitted.append($0) }
        XCTAssertEqual(submitted, Data([0xaa]))
        XCTAssertTrue(order.readyToPresent(fenceCompleted: { _ in false }).isEmpty)
        // Renderer completion can drain the final frame without another chunk.
        XCTAssertEqual(order.readyToPresent(fenceCompleted: { _ in true }).map(\.frameID), [1])
        XCTAssertTrue(order.readyToPresent(fenceCompleted: { _ in true }).isEmpty)
    }

    func testLaterFrameDoesNotOvertakeAnIncompleteFence() throws {
        let order = RemoteGPUFrameOrder()
        try order.consumeVTest(RemoteGPUVTestChunk(sequence: 1, bytes: Data()).envelope.payload) { _ in }
        try order.enqueuePresent(present(frame: 1, after: 1))
        try order.enqueuePresent(present(frame: 2, after: 1))
        XCTAssertTrue(order.readyToPresent(fenceCompleted: { $0.frameID == 2 }).isEmpty)
        XCTAssertEqual(order.readyToPresent(fenceCompleted: { _ in true }).map(\.frameID), [1, 2])
    }

    func testRejectedSubmissionDoesNotAdvanceSequence() throws {
        let order = RemoteGPUFrameOrder()
        let chunk = RemoteGPUVTestChunk(sequence: 1, bytes: Data([0x01]))
        XCTAssertThrowsError(try order.consumeVTest(chunk.envelope.payload) { _ in
            throw RemoteGPUProtocolError.invalidVTestChunk
        })
        XCTAssertEqual(order.processedSequence, 0)
        XCTAssertThrowsError(try RemoteGPUPresent(payload: Data(repeating: 0, count: 47)))
    }

    func testStrictDisplayOrderRequiresExactSequenceAndFrame() throws {
        let order = RemoteGPUSerialDisplayOrder()
        let vtest = RemoteGPUVTestChunk(sequence: 1, bytes: Data([0x01])).envelope.payload
        try order.consume(vtest) { _ in }
        for payload in [present(frame: 1, after: 0), present(frame: 1, after: 2), present(frame: 0, after: 1), present(frame: 2, after: 1)] {
            XCTAssertThrowsError(try order.beginPresent(payload))
        }
        var invalidResource = present(frame: 1, after: 1)
        invalidResource.replaceSubrange(8..<16, with: Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try order.beginPresent(invalidResource))
        invalidResource[8] = 1 // > UInt32.max
        XCTAssertThrowsError(try order.beginPresent(invalidResource))
        var invalidRegion = present(frame: 1, after: 1)
        invalidRegion[35] = 1
        XCTAssertThrowsError(try order.beginPresent(invalidRegion))
        let frame = try order.beginPresent(present(frame: 1, after: 1))
        XCTAssertThrowsError(try order.consume(RemoteGPUVTestChunk(sequence: 2, bytes: Data([2])).envelope.payload) { _ in
            XCTFail("Later GPU commands escaped the snapshot barrier")
        })
        XCTAssertThrowsError(try order.beginPresent(present(frame: 2, after: 1)))
        try order.completePresent(frame)
        XCTAssertEqual(order.displayedFrame, 1)
        XCTAssertThrowsError(try order.beginPresent(present(frame: 1, after: 1)))
        try order.consume(RemoteGPUVTestChunk(sequence: 2, bytes: Data([2])).envelope.payload) { _ in }
    }

    func testCancelledDisplayCannotSubmitOrCompleteSnapshot() throws {
        let order = RemoteGPUSerialDisplayOrder()
        try order.consume(RemoteGPUVTestChunk(sequence: 1, bytes: Data([1])).envelope.payload) { _ in }
        let frame = try order.beginPresent(present(frame: 1, after: 1))
        order.cancel()
        XCTAssertThrowsError(try order.completePresent(frame))
        XCTAssertThrowsError(try order.consume(RemoteGPUVTestChunk(sequence: 2, bytes: Data([2])).envelope.payload) { _ in XCTFail() })
        XCTAssertEqual(order.displayedFrame, 0)
    }

    func testBoundedIngressBackpressureAndCancellation() throws {
        let gate = RemoteGPUBoundedIngress()
        let envelope = RemoteGPUEnvelope(type: .vtestBytes, flags: 0, payload: Data([1]))
        let ticket = try gate.admit([envelope])
        XCTAssertThrowsError(try gate.admit([envelope])) // Consumer/GPU still busy.
        XCTAssertTrue(gate.complete(ticket))
        XCTAssertFalse(gate.complete(ticket)) // No double receive on duplicate callback.
        XCTAssertThrowsError(try gate.admit(Array(repeating: envelope, count: 4097)))
        XCTAssertThrowsError(try gate.admit([RemoteGPUEnvelope(type: .vtestBytes, flags: 0,
            payload: Data(repeating: 0, count: RemoteGPUBoundedIngress.byteBudget))]))
        let last = try gate.admit([envelope])
        gate.cancel()
        XCTAssertFalse(gate.complete(last))
        XCTAssertThrowsError(try gate.admit([envelope]))
        XCTAssertEqual(gate.highWaterBytes, 11)
    }

    func testFiniteDiagnosticFrameBudget() throws {
        let order = RemoteGPUSerialDisplayOrder()
        try order.consume(RemoteGPUVTestChunk(sequence: 1, bytes: Data([1])).envelope.payload) { _ in }
        for frame in 1...16 {
            let next = try order.beginPresent(present(frame: UInt64(frame), after: 1))
            try order.completePresent(next)
        }
        XCTAssertThrowsError(try order.beginPresent(present(frame: 17, after: 1)))
    }
}
