import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class RTPTests: XCTestCase {
    func testEncodesAndDecodesMinimalRTPPacket() throws {
        let packet = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 42,
            timestamp: 123_456,
            ssrc: 0x0102_0304,
            payload: Data([0x65, 0x88, 0x84])
        )

        let decoded = try RTPPacket(decoding: packet.encoded())

        XCTAssertEqual(decoded, packet)
    }

    func testRejectsUnsupportedRTPVersion() throws {
        let packet = RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: 1,
            timestamp: 1,
            ssrc: 1,
            payload: Data([0x01])
        )
        var encoded = packet.encoded()
        encoded[0] = 0x40

        XCTAssertThrowsError(try RTPPacket(decoding: encoded)) { error in
            XCTAssertEqual(error as? RTPError, .unsupportedVersion(1))
        }
    }
}
