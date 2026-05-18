import Foundation
import AVFoundation
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

    func testOpusReceivePipelineSchedulesDecodedAudioWhenPlayoutIsConfigured() throws {
        let opusPacket: OpusPacket
        do {
            opusPacket = try makeEncodedOpusPacket()
        } catch let error as OpusAudioPipelineError {
            throw XCTSkip("AudioToolbox Opus encoder unavailable in this environment: \(error)")
        }

        let audioPlayoutPipeline = OpusAudioPlayoutPipeline()
        let pipeline = SubscriberMediaReceivePipeline(audioPlayoutPipeline: audioPlayoutPipeline)
        let packet = RTPPacket(
            marker: false,
            payloadType: 111,
            sequenceNumber: 1,
            timestamp: 960,
            ssrc: 0x1111_2222,
            payload: opusPacket.payload
        )

        let result = pipeline.append(packet)

        guard result.audioPlayoutErrorCount == 0 else {
            throw XCTSkip("AudioToolbox Opus playout unavailable in this environment.")
        }
        XCTAssertEqual(result.opusPackets.map(\.payload), [opusPacket.payload])
        XCTAssertEqual(result.decodedAudioBufferCount, 1)
        XCTAssertEqual(result.audioPlayoutErrorCount, 0)
        XCTAssertEqual(audioPlayoutPipeline.scheduledBufferCount, 1)
        XCTAssertEqual(pipeline.audioPlayoutScheduledBufferCount, 1)

        pipeline.reset()

        XCTAssertEqual(audioPlayoutPipeline.scheduledBufferCount, 0)
        XCTAssertEqual(pipeline.audioPlayoutScheduledBufferCount, 0)
    }

    func testReceiverReportTracksObservedRTPAndSenderReports() throws {
        let pipeline = SubscriberMediaReceivePipeline()
        let mediaSSRC: UInt32 = 0x1111_2222

        _ = pipeline.append(
            RTPPacket(
                marker: false,
                payloadType: 111,
                sequenceNumber: 10,
                timestamp: 960,
                ssrc: mediaSSRC,
                payload: Data([0x08])
            )
        )
        pipeline.observeRTCP(
            .senderReport(
                RTCPSenderReport(
                    senderSSRC: mediaSSRC,
                    ntpTimestamp: 0x0102_0304_0506_0708,
                    rtpTimestamp: 960,
                    packetCount: 1,
                    octetCount: 1
                )
            ),
            receivedAt: 100
        )
        _ = pipeline.append(
            RTPPacket(
                marker: false,
                payloadType: 111,
                sequenceNumber: 12,
                timestamp: 1_920,
                ssrc: mediaSSRC,
                payload: Data([0x08])
            )
        )

        let packet = try XCTUnwrap(pipeline.receiverReport(senderSSRC: 0x0102_0304, now: 100.25))
        guard case let .receiverReport(report) = packet else {
            return XCTFail("Expected receiver report.")
        }

        let receptionReport = try XCTUnwrap(report.reports.first)
        XCTAssertEqual(report.senderSSRC, 0x0102_0304)
        XCTAssertEqual(receptionReport.ssrc, mediaSSRC)
        XCTAssertEqual(receptionReport.highestSequenceNumber, 12)
        XCTAssertEqual(receptionReport.cumulativePacketsLost, 1)
        XCTAssertEqual(receptionReport.fractionLost, 85)
        XCTAssertEqual(receptionReport.lastSenderReport, 0x0304_0506)
        XCTAssertEqual(receptionReport.delaySinceLastSenderReport, 16_384)
    }

    private func makeEncodedOpusPacket() throws -> OpusPacket {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = sin(Float(frame) * 0.01) * 0.1
        }

        return try OpusAudioConverterEncoder().encode(buffer)
    }
}
