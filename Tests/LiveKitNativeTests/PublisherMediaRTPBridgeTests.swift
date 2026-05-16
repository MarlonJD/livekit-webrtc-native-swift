import Foundation
import XCTest
@testable import LiveKitNative
@testable import LiveKitNativeWebRTC

final class PublisherMediaRTPBridgeTests: XCTestCase {
    func testAudioSenderKeepsPacketizerSequenceAndTimestampAcrossPackets() async throws {
        let track = try LocalAudioTrack.createTrack(
            options: AudioCaptureOptions(sampleRate: 48_000, channelCount: 1, frameDurationMilliseconds: 20)
        )
        let plan = LocalAudioPublishPlan(track: track, ssrc: 0x0102_0304, payloadType: 111)
        let sink = RTPPacketSink()
        let bridge = PublisherMediaRTPBridge { packet in
            await sink.append(packet)
        }
        let sender = bridge.audioSender(for: plan)

        let first = try await sender.send(try OpusPacket(payload: Data([0x08, 0xAA])))
        let second = try await sender.send(try OpusPacket(payload: Data([0x08, 0xBB])))

        XCTAssertEqual(first.sequenceNumber, 0)
        XCTAssertEqual(second.sequenceNumber, 1)
        XCTAssertEqual(first.timestamp, 0)
        XCTAssertEqual(second.timestamp, 960)
        XCTAssertEqual(first.ssrc, 0x0102_0304)
        XCTAssertEqual(second.payloadType, 111)

        let sentPackets = await sink.packets
        XCTAssertEqual(sentPackets, [first, second])
    }

    func testVideoSenderKeepsPacketizerSequenceAcrossFrames() async throws {
        let track = try LocalVideoTrack.createCameraTrack(
            options: CameraCaptureOptions(width: 640, height: 360, framesPerSecond: 30)
        )
        let plan = LocalVideoPublishPlan(track: track, ssrc: 0x1122_3344, payloadType: 102)
        let sink = RTPPacketSink()
        let bridge = PublisherMediaRTPBridge { packet in
            await sink.append(packet)
        }
        let sender = bridge.videoSender(for: plan)

        let first = try await sender.send(
            H264EncodedFrame(nalUnits: [Data([0x65, 0x01, 0x02])], rtpTimestamp: 90_000, isKeyFrame: true)
        )
        let second = try await sender.send(
            H264EncodedFrame(nalUnits: [Data([0x41, 0x03, 0x04])], rtpTimestamp: 93_000)
        )

        XCTAssertEqual(first.map(\.sequenceNumber), [0])
        XCTAssertEqual(second.map(\.sequenceNumber), [1])
        XCTAssertEqual(first.first?.timestamp, 90_000)
        XCTAssertEqual(second.first?.timestamp, 93_000)
        XCTAssertEqual(first.first?.ssrc, 0x1122_3344)
        XCTAssertEqual(second.first?.payloadType, 102)

        let sentPackets = await sink.packets
        XCTAssertEqual(sentPackets, first + second)
    }
}

private actor RTPPacketSink {
    private var storage: [RTPPacket] = []

    var packets: [RTPPacket] {
        storage
    }

    func append(_ packet: RTPPacket) {
        storage.append(packet)
    }
}
