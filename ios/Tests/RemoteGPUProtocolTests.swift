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
        for value: UInt32 in [0, 0, 0, 0, 64, 64] {
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
}
