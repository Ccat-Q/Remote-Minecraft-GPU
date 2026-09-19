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
}
