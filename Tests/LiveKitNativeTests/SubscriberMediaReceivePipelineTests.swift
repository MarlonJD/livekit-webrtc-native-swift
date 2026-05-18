import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class SubscriberMediaReceivePipelineTests: XCTestCase {
    func testH264ReceivePipelineReleasesFramesAndRequestsFeedbackForLossAndMissingParameterSets() throws {
        let pipeline = SubscriberMediaReceivePipeline(
            feedbackSenderSSRC: 0x0102_0304,
            maxBufferedPackets: 0
        )
        let first = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 10,
            timestamp: 90_000,
            ssrc: 0x0506_0708,
            payload: Data([0x65, 0x88, 0x84])
        )
        let second = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 12,
            timestamp: 93_000,
            ssrc: 0x0506_0708,
            payload: Data([0x41, 0x9A])
        )

        let firstResult = pipeline.append(first)
        XCTAssertEqual(firstResult.h264AccessUnits.count, 1)
        XCTAssertEqual(
            firstResult.feedbackPackets,
            [
                .pictureLossIndication(
                    RTCPPictureLossIndication(
                        senderSSRC: 0x0102_0304,
                        mediaSSRC: 0x0506_0708
                    )
                ),
            ]
        )

        let secondResult = pipeline.append(second)
        XCTAssertEqual(secondResult.missingSequenceNumbers, [11])
        XCTAssertEqual(secondResult.h264AccessUnits.count, 1)
        XCTAssertEqual(
            secondResult.feedbackPackets,
            [
                .transportLayerNACK(
                    RTCPTransportLayerNACK(
                        senderSSRC: 0x0102_0304,
                        mediaSSRC: 0x0506_0708,
                        lostPacketIDs: [11]
                    )
                ),
                .pictureLossIndication(
                    RTCPPictureLossIndication(
                        senderSSRC: 0x0102_0304,
                        mediaSSRC: 0x0506_0708
                    )
                ),
            ]
        )
    }

    func testOpusReceivePipelineDepacketizesAudioPayloads() throws {
        let pipeline = SubscriberMediaReceivePipeline()
        let packet = RTPPacket(
            marker: false,
            payloadType: 111,
            sequenceNumber: 1,
            timestamp: 960,
            ssrc: 0x1111_2222,
            payload: Data([0x08, 0xAA])
        )

        let result = pipeline.append(packet)

        XCTAssertEqual(result.opusPackets.map(\.payload), [Data([0x08, 0xAA])])
        XCTAssertEqual(result.feedbackPackets, [])
    }
}
