import XCTest
@testable import LiveKitNativeWebRTC

final class SubscribeRTCPFeedbackPlannerTests: XCTestCase {
    func testH264SequenceNumberGapBuildsTransportLayerNACK() {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: 0x0102_0304,
            mediaSSRC: 0x0506_0708,
            h264Error: .sequenceNumberGap(expected: 100, actual: 104)
        )

        XCTAssertEqual(
            packets,
            [
                .transportLayerNACK(
                    RTCPTransportLayerNACK(
                        senderSSRC: 0x0102_0304,
                        mediaSSRC: 0x0506_0708,
                        lostPacketIDs: [100, 101, 102, 103]
                    )
                )
            ]
        )
    }

    func testVP8SequenceNumberGapBuildsTransportLayerNACK() {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: 1,
            mediaSSRC: 2,
            vp8Error: .sequenceNumberGap(expected: 7, actual: 10)
        )

        XCTAssertEqual(
            packets,
            [
                .transportLayerNACK(
                    RTCPTransportLayerNACK(
                        senderSSRC: 1,
                        mediaSSRC: 2,
                        lostPacketIDs: [7, 8, 9]
                    )
                )
            ]
        )
    }

    func testSequenceNumberGapWrapBuildsBoundedTransportLayerNACK() {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: 1,
            mediaSSRC: 2,
            h264Error: .sequenceNumberGap(expected: UInt16.max - 1, actual: 2)
        )

        XCTAssertEqual(
            packets,
            [
                .transportLayerNACK(
                    RTCPTransportLayerNACK(
                        senderSSRC: 1,
                        mediaSSRC: 2,
                        lostPacketIDs: [0, 1, UInt16.max - 1, UInt16.max]
                    )
                )
            ]
        )
    }

    func testOldOrReorderedSequenceNumberDoesNotBuildOversizedNACK() {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: 1,
            mediaSSRC: 2,
            vp8Error: .sequenceNumberGap(expected: 42, actual: 40)
        )

        XCTAssertEqual(packets, [])
    }

    func testLargeForwardGapIsCappedToBoundedNACKWindow() {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: 1,
            mediaSSRC: 2,
            h264Error: .sequenceNumberGap(expected: 100, actual: 700)
        )

        guard case let .transportLayerNACK(nack)? = packets.first else {
            return XCTFail("Expected transport layer NACK")
        }

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(nack.lostPacketIDs.count, SubscribeRTCPFeedbackPlanner.maximumMissingSequenceNumbers)
        XCTAssertEqual(nack.lostPacketIDs.first, 100)
        XCTAssertEqual(nack.lostPacketIDs.last, 611)
    }

    func testNonGapAndEmptyLossDoNotBuildPackets() {
        let planner = SubscribeRTCPFeedbackPlanner()

        XCTAssertEqual(
            planner.feedbackPackets(
                senderSSRC: 1,
                mediaSSRC: 2,
                signals: [
                    .h264RTPError(.missingFragmentStart),
                    .vp8RTPError(.emptyPayload),
                    .missingSequenceNumbers([])
                ]
            ),
            []
        )
        XCTAssertEqual(
            planner.feedbackPackets(
                senderSSRC: 1,
                mediaSSRC: 2,
                h264Error: .sequenceNumberGap(expected: 42, actual: 42)
            ),
            []
        )
    }

    func testKeyFrameRequestBuildsPLI() {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: 0x0102_0304,
            mediaSSRC: 0x0506_0708,
            signals: [.keyFrameRequest]
        )

        XCTAssertEqual(
            packets,
            [
                .pictureLossIndication(
                    RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
                )
            ]
        )
    }

    func testCombinedLossAndKeyFrameRequestUsesPolicyOrdering() {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: 0x0102_0304,
            mediaSSRC: 0x0506_0708,
            signals: [
                .vp8RTPError(.sequenceNumberGap(expected: 9, actual: 11)),
                .keyFrameRequest
            ]
        )

        XCTAssertEqual(
            packets,
            [
                .transportLayerNACK(
                    RTCPTransportLayerNACK(
                        senderSSRC: 0x0102_0304,
                        mediaSSRC: 0x0506_0708,
                        lostPacketIDs: [9, 10]
                    )
                ),
                .pictureLossIndication(
                    RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
                )
            ]
        )
    }
}
