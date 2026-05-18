import AVFoundation
import XCTest
@testable import LiveKitNativeWebRTC

final class OpusAudioPipelineTests: XCTestCase {
    func testOpusVoiceProfileDefaultsMatchWebRTCProfile() {
        let profile = OpusVoiceProfile()

        XCTAssertEqual(profile.payloadType, 111)
        XCTAssertEqual(profile.clockRate, 48_000)
        XCTAssertEqual(profile.channelCount, 1)
        XCTAssertEqual(profile.frameDurationMilliseconds, 20)
        XCTAssertEqual(profile.mimeType, "audio/opus")
    }

    func testParsesSingleMonoFrameTOC() throws {
        let packet = try OpusPacket(payload: Data([0x08, 0xAA]))

        XCTAssertEqual(packet.toc.configuration, 1)
        XCTAssertFalse(packet.toc.isStereo)
        XCTAssertEqual(packet.toc.frameCountCode, 0)
        XCTAssertEqual(packet.toc.frameCount, 1)
        XCTAssertEqual(packet.toc.frameDurationMicroseconds, 20_000)
        XCTAssertEqual(packet.toc.packetDurationMicroseconds, 20_000)
    }

    func testParsesCode3FrameCount() throws {
        let packet = try OpusPacket(payload: Data([0x03, 0x82, 0xAA, 0xBB]))

        XCTAssertEqual(packet.toc.frameCountCode, 3)
        XCTAssertEqual(packet.toc.frameCount, 2)
        XCTAssertEqual(packet.toc.packetDurationMicroseconds, 20_000)
    }

    func testRejectsEmptyPacketAndInvalidFrameCount() {
        XCTAssertThrowsError(try OpusPacket(payload: Data())) { error in
            XCTAssertEqual(error as? OpusPacketError, .emptyPacket)
        }

        XCTAssertThrowsError(try OpusPacket(payload: Data([0x03]))) { error in
            XCTAssertEqual(error as? OpusPacketError, .invalidFrameCount)
        }
    }

    func testOpusRTPPacketizerAdvancesTimestampByPacketDuration() throws {
        let packet = try OpusPacket(payload: Data([0x08, 0xAA]))
        let packetizer = OpusRTPPacketizer(
            payloadType: 111,
            ssrc: 4_321,
            startingSequenceNumber: 10,
            startingTimestamp: 90_000
        )

        let first = packetizer.packetize(packet)
        let second = packetizer.packetize(packet)

        XCTAssertEqual(first.payloadType, 111)
        XCTAssertEqual(first.sequenceNumber, 10)
        XCTAssertEqual(first.timestamp, 90_000)
        XCTAssertEqual(first.ssrc, 4_321)
        XCTAssertEqual(first.payload, packet.payload)
        XCTAssertEqual(second.sequenceNumber, 11)
        XCTAssertEqual(second.timestamp, 90_960)
    }

    func testOpusRTPDepacketizerReturnsOpusPacket() throws {
        let rtpPacket = RTPPacket(
            marker: false,
            payloadType: 111,
            sequenceNumber: 1,
            timestamp: 960,
            ssrc: 7,
            payload: Data([0x08, 0xCC])
        )

        let opusPacket = try OpusRTPDepacketizer().depacketize(rtpPacket)

        XCTAssertEqual(opusPacket.payload, Data([0x08, 0xCC]))
        XCTAssertEqual(opusPacket.toc.packetDurationMicroseconds, 20_000)
    }

    func testOpusSubscribePipelineDepacketizesAndTracksDrops() throws {
        let pipeline = OpusSubscribePipeline(expectedPayloadType: 111)

        let first = RTPPacket(
            marker: false,
            payloadType: 111,
            sequenceNumber: 10,
            timestamp: 0,
            ssrc: 9,
            payload: Data([0x08, 0xAA])
        )
        let second = RTPPacket(
            marker: false,
            payloadType: 111,
            sequenceNumber: 12,
            timestamp: 1_920,
            ssrc: 9,
            payload: Data([0x08, 0xBB])
        )

        XCTAssertEqual(try pipeline.append(first).payload, Data([0x08, 0xAA]))
        XCTAssertEqual(try pipeline.append(second).payload, Data([0x08, 0xBB]))
        XCTAssertEqual(pipeline.droppedPacketCount, 1)
    }

    func testOpusSubscribePipelineRejectsUnexpectedPayloadType() {
        let pipeline = OpusSubscribePipeline(expectedPayloadType: 111)
        let packet = RTPPacket(
            marker: false,
            payloadType: 112,
            sequenceNumber: 1,
            timestamp: 0,
            ssrc: 9,
            payload: Data([0x08, 0xAA])
        )

        XCTAssertThrowsError(try pipeline.append(packet)) { error in
            XCTAssertEqual(
                error as? OpusAudioPipelineError,
                .payloadTypeMismatch(expected: 111, actual: 112)
            )
        }
    }

    func testNativeAudioPlayoutSourceCarriesConfiguration() {
        let source = NativeAudioPlayoutSource(
            configuration: NativeAudioPlayoutConfiguration(sampleRate: 48_000, channelCount: 2)
        )

        XCTAssertEqual(source.configuration.sampleRate, 48_000)
        XCTAssertEqual(source.configuration.channelCount, 2)
        XCTAssertFalse(source.isRunning)
        XCTAssertEqual(source.scheduledBufferCount, 0)
    }

    func testAudioPlayoutPipelineDecodesAndSchedulesBuffer() throws {
        let packet = try makeEncodedOpusPacket()
        let source = NativeAudioPlayoutSource()
        let pipeline = OpusAudioPlayoutPipeline(source: source)

        let decoded: AVAudioPCMBuffer
        do {
            decoded = try pipeline.append(packet)
        } catch let error as OpusAudioPipelineError {
            throw XCTSkip("AudioToolbox Opus playout unavailable in this environment: \(error)")
        }

        XCTAssertGreaterThan(decoded.frameLength, 0)
        XCTAssertEqual(pipeline.decodedBufferCount, 1)
        XCTAssertEqual(pipeline.scheduledBufferCount, 1)
        XCTAssertEqual(source.scheduledBufferCount, 1)

        pipeline.reset()

        XCTAssertEqual(pipeline.decodedBufferCount, 0)
        XCTAssertEqual(pipeline.scheduledBufferCount, 0)
    }

    func testAudioToolboxOpusEncoderAndDecoderRoundTripPCMBuffer() throws {
        let packet: OpusPacket
        do {
            packet = try makeEncodedOpusPacket()
        } catch let error as OpusAudioPipelineError {
            throw XCTSkip("AudioToolbox Opus encoder unavailable in this environment: \(error)")
        }

        XCTAssertFalse(packet.payload.isEmpty)

        let decoder = OpusAudioConverterDecoder()
        let decoded: AVAudioPCMBuffer
        do {
            decoded = try decoder.decode(packet)
        } catch let error as OpusAudioPipelineError {
            throw XCTSkip("AudioToolbox Opus decoder unavailable in this environment: \(error)")
        }

        XCTAssertGreaterThan(decoded.frameLength, 0)
        XCTAssertEqual(decoded.format.sampleRate, 48_000)
        XCTAssertEqual(decoded.format.channelCount, 1)
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
