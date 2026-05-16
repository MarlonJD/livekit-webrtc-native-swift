import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class RTCPFeedbackPolicyTests: XCTestCase {
    func testBuildsGenericNACKWithPackedBitmaskGroups() throws {
        let packet = try XCTUnwrap(
            RTCPFeedbackPolicy().transportLayerNACK(
                senderSSRC: 0x0102_0304,
                mediaSSRC: 0x0506_0708,
                missingSequenceNumbers: [120, 103, 100, 101, 100]
            )
        )

        guard case let .transportLayerNACK(nack) = packet else {
            return XCTFail("Expected transport layer NACK")
        }

        XCTAssertEqual(nack.lostPacketIDs, [100, 101, 103, 120])

        let encoded = try packet.encoded()
        XCTAssertEqual(encoded[0], 0x81)
        XCTAssertEqual(encoded[1], 205)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 12), 100)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 14), 0b0000_0000_0000_0101)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 16), 120)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 18), 0)
    }

    func testBuildsNewNACKEntryForLossesOutsideBitmaskWindow() throws {
        let packet = try XCTUnwrap(
            RTCPFeedbackPolicy().transportLayerNACK(
                senderSSRC: 1,
                mediaSSRC: 2,
                missingSequenceNumbers: [59, 42, 75, 58]
            )
        )
        let encoded = try packet.encoded()

        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 12), 42)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 14), 0b1000_0000_0000_0000)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 16), 59)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 18), 0b1000_0000_0000_0000)
    }

    func testBuildsDeterministicNACKEntriesAcrossSequenceWrap() throws {
        let packet = try XCTUnwrap(
            RTCPFeedbackPolicy().transportLayerNACK(
                senderSSRC: 1,
                mediaSSRC: 2,
                missingSequenceNumbers: [UInt16.max, 0, 1, UInt16.max]
            )
        )

        guard case let .transportLayerNACK(nack) = packet else {
            return XCTFail("Expected transport layer NACK")
        }

        XCTAssertEqual(nack.lostPacketIDs, [0, 1, UInt16.max])

        let encoded = try packet.encoded()
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 12), 0)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 14), 0b0000_0000_0000_0001)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 16), UInt16.max)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 18), 0)
    }

    func testEmptyMissingSequenceNumbersDoNotEmitNACK() {
        let policy = RTCPFeedbackPolicy()

        XCTAssertNil(
            policy.transportLayerNACK(
                senderSSRC: 1,
                mediaSSRC: 2,
                missingSequenceNumbers: []
            )
        )
        XCTAssertEqual(
            policy.feedbackPackets(senderSSRC: 1, mediaSSRC: 2, missingSequenceNumbers: []),
            []
        )
    }

    func testBuildsPictureLossIndicationAndCombinedFeedbackOrder() {
        let policy = RTCPFeedbackPolicy()
        let pli = policy.pictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)

        XCTAssertEqual(
            pli,
            .pictureLossIndication(
                RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
            )
        )

        let packets = policy.feedbackPackets(
            senderSSRC: 0x0102_0304,
            mediaSSRC: 0x0506_0708,
            missingSequenceNumbers: [7],
            requestsKeyFrame: true
        )

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(
            packets[0],
            .transportLayerNACK(
                RTCPTransportLayerNACK(
                    senderSSRC: 0x0102_0304,
                    mediaSSRC: 0x0506_0708,
                    lostPacketIDs: [7]
                )
            )
        )
        XCTAssertEqual(packets[1], pli)
    }
}

private extension Data {
    func networkUInt16ForTest(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw RTCPError.invalidLength
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return UInt16(self[first]) << 8 | UInt16(self[second])
    }
}
