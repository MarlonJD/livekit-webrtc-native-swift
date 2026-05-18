import Foundation
import CoreMedia
import CoreVideo
import XCTest
@testable import LiveKitNativeWebRTC

final class H264RTPTests: XCTestCase {
    func testPacketizesAndDepacketizesSingleNALUnit() throws {
        let nalUnit = Data([0x65, 0x88, 0x84, 0x21])
        let packetizer = H264RTPPacketizer(payloadType: 102, mtu: 1_200)
        let packets = try packetizer.packetize(
            nalUnits: [nalUnit],
            timestamp: 9_000,
            ssrc: 0x0102_0304,
            startingSequenceNumber: 12
        )

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].marker, true)
        XCTAssertEqual(packets[0].sequenceNumber, 12)
        XCTAssertEqual(packets[0].payload, nalUnit)

        let depacketizer = H264RTPDepacketizer()
        XCTAssertEqual(try depacketizer.append(packets[0]), [nalUnit])
    }

    func testPacketizesAndDepacketizesFUAFragments() throws {
        let nalUnit = Data([0x65] + Array(1...24))
        let packetizer = H264RTPPacketizer(payloadType: 102, mtu: 20)
        let packets = try packetizer.packetize(
            nalUnits: [nalUnit],
            timestamp: 90_000,
            ssrc: 0x0A0B_0C0D,
            startingSequenceNumber: 65_530
        )

        XCTAssertGreaterThan(packets.count, 1)
        XCTAssertEqual(packets.first?.payload.first, 0x7C)
        XCTAssertEqual(packets.first?.payload.dropFirst().first.map { $0 & 0x80 }, 0x80)
        XCTAssertEqual(packets.last?.payload.dropFirst().first.map { $0 & 0x40 }, 0x40)
        XCTAssertEqual(packets.last?.marker, true)

        let depacketizer = H264RTPDepacketizer()
        var output: [Data] = []
        for packet in packets {
            output.append(contentsOf: try depacketizer.append(packet))
        }

        XCTAssertEqual(output, [nalUnit])
    }

    func testBuildsAndDepacketizesSTAPAParameterSets() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x06, 0xE2])
        let payload = try H264RTPPacketizer.makeSTAPA(nalUnits: [sps, pps])
        let packet = RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: 77,
            timestamp: 1_000,
            ssrc: 42,
            payload: payload
        )

        XCTAssertEqual(payload.first.map { $0 & 0x1F }, H264NALUnitType.stapA.rawValue)
        XCTAssertEqual(try H264RTPDepacketizer().append(packet), [sps, pps])
    }

    func testSubscribePipelineBuildsAnnexBAccessUnitOnMarker() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x06, 0xE2])
        let idr = Data([0x65, 0x88, 0x84])
        let stapA = try H264RTPPacketizer.makeSTAPA(nalUnits: [sps, pps])
        let pipeline = H264SubscribePipeline()

        let parameterSetPacket = RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: 1,
            timestamp: 90_000,
            ssrc: 99,
            payload: stapA
        )
        let framePacket = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 2,
            timestamp: 90_000,
            ssrc: 99,
            payload: idr
        )

        XCTAssertEqual(try pipeline.append(parameterSetPacket), [])
        let accessUnits = try pipeline.append(framePacket)

        XCTAssertEqual(accessUnits.count, 1)
        XCTAssertEqual(accessUnits[0].timestamp, 90_000)
        XCTAssertEqual(accessUnits[0].nalUnits, [sps, pps, idr])
        XCTAssertEqual(
            accessUnits[0].annexBData,
            Data([0, 0, 0, 1]) + sps + Data([0, 0, 0, 1]) + pps + Data([0, 0, 0, 1]) + idr
        )
    }

    func testVideoToolboxDecoderCapturesParameterSets() throws {
        let accessUnit = H264AccessUnit(
            timestamp: 90_000,
            nalUnits: [
                Data([0x67, 0x42, 0x00, 0x1F, 0xE5, 0x40, 0x28, 0x02, 0xDD, 0x80]),
                Data([0x68, 0xCE, 0x06, 0xE2]),
            ]
        )
        let decoder = H264VideoToolboxSubscribeDecoder()

        decoder.configureIfPossible(from: accessUnit)

        XCTAssertTrue(decoder.hasParameterSets)
    }

    func testPublishPacketizerMaintainsSequenceNumbersAcrossFrames() throws {
        let packetizer = H264PublishRTPPacketizer(
            payloadType: 102,
            mtu: 1_200,
            ssrc: 42,
            startingSequenceNumber: 10
        )
        let firstFrame = H264EncodedFrame(nalUnits: [Data([0x65, 0x01])], rtpTimestamp: 90_000, isKeyFrame: true)
        let secondFrame = H264EncodedFrame(nalUnits: [Data([0x41, 0x02])], rtpTimestamp: 93_000)

        let firstPackets = try packetizer.packetize(firstFrame)
        let secondPackets = try packetizer.packetize(secondFrame)

        XCTAssertEqual(firstPackets.map(\.sequenceNumber), [10])
        XCTAssertEqual(secondPackets.map(\.sequenceNumber), [11])
        XCTAssertEqual(firstPackets.first?.ssrc, 42)
        XCTAssertEqual(secondPackets.first?.timestamp, 93_000)
    }

    func testVideoToolboxEncoderProducesH264NALUnitsFromPixelBuffer() throws {
        let recorder = H264EncodedFrameRecorder()
        let didEncode = expectation(description: "VideoToolbox encoder produced a frame")
        let encoder = H264VideoToolboxEncoder(
            settings: H264EncoderSettings(
                width: 16,
                height: 16,
                framesPerSecond: 30,
                bitrate: 100_000
            )
        )

        do {
            try encoder.configure { frame in
                recorder.record(frame)
                didEncode.fulfill()
            }
            try encoder.encode(
                pixelBuffer: Self.makeNV12PixelBuffer(width: 16, height: 16),
                presentationTimeStamp: CMTime(value: 0, timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
            try encoder.completeFrames()
        } catch let error as H264VideoToolboxEncoderError {
            throw XCTSkip("VideoToolbox H.264 encoder unavailable in this environment: \(error)")
        }

        wait(for: [didEncode], timeout: 2.0)
        let frames = recorder.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(try XCTUnwrap(frames.first).nalUnits.isEmpty)
        XCTAssertEqual(frames.first?.rtpTimestamp, 0)
    }

    func testVideoToolboxDecoderProducesPixelBufferFromEncodedFrame() throws {
        let encodedFrame = try makeEncodedH264Frame()
        let decoder = H264VideoToolboxSubscribeDecoder()
        let accessUnit = H264AccessUnit(timestamp: encodedFrame.rtpTimestamp, nalUnits: encodedFrame.nalUnits)

        let decodedFrames: [H264DecodedFrame]
        do {
            decodedFrames = try decoder.decode(accessUnit)
        } catch let error as H264VideoToolboxSubscribeDecoderError {
            throw XCTSkip("VideoToolbox H.264 decoder unavailable in this environment: \(error)")
        }

        let decodedFrame = try XCTUnwrap(decodedFrames.first)
        XCTAssertEqual(decoder.decodedFrameCount, 1)
        XCTAssertEqual(decodedFrame.timestamp, encodedFrame.rtpTimestamp)
        XCTAssertEqual(CVPixelBufferGetWidth(decodedFrame.pixelBuffer), 16)
        XCTAssertEqual(CVPixelBufferGetHeight(decodedFrame.pixelBuffer), 16)
        XCTAssertNotNil(decoder.lastDecodedFrame)
    }

    func testVideoToolboxEncoderAppliesAdaptiveQualityRecommendation() {
        let encoder = H264VideoToolboxEncoder(
            settings: H264EncoderSettings(
                width: 1_280,
                height: 720,
                framesPerSecond: 30,
                bitrate: 1_500_000
            )
        )
        let recommendation = AdaptiveVideoQualityRecommendation(
            level: .low,
            targetBitrateBps: 500_000,
            maxWidth: 640,
            maxHeight: 360,
            maxFramesPerSecond: 15
        )

        encoder.applyQualityRecommendation(recommendation)

        XCTAssertEqual(encoder.targetBitrate, 500_000)
        XCTAssertEqual(encoder.targetFramesPerSecond, 15)
        XCTAssertEqual(encoder.appliedQualityRecommendation, recommendation)
    }

    func testDetectsMissingFUAStart() {
        let packet = RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: 1,
            timestamp: 1,
            ssrc: 1,
            payload: Data([0x7C, 0x05, 0xAA])
        )

        XCTAssertThrowsError(try H264RTPDepacketizer().append(packet)) { error in
            XCTAssertEqual(error as? H264RTPError, .missingFragmentStart)
        }
    }

    private func makeEncodedH264Frame() throws -> H264EncodedFrame {
        let recorder = H264EncodedFrameRecorder()
        let didEncode = expectation(description: "VideoToolbox encoder produced a frame for decode")
        let encoder = H264VideoToolboxEncoder(
            settings: H264EncoderSettings(
                width: 16,
                height: 16,
                framesPerSecond: 30,
                bitrate: 100_000
            )
        )

        do {
            try encoder.configure { frame in
                recorder.record(frame)
                didEncode.fulfill()
            }
            try encoder.encode(
                pixelBuffer: Self.makeNV12PixelBuffer(width: 16, height: 16),
                presentationTimeStamp: CMTime(value: 1, timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
            try encoder.completeFrames()
        } catch let error as H264VideoToolboxEncoderError {
            throw XCTSkip("VideoToolbox H.264 encoder unavailable in this environment: \(error)")
        }

        wait(for: [didEncode], timeout: 2.0)
        return try XCTUnwrap(recorder.frames.first)
    }

    private static func makeNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw H264TestError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                continue
            }
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            memset(baseAddress, 0x80, height * bytesPerRow)
        }

        return pixelBuffer
    }
}

private final class H264EncodedFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mutableFrames: [H264EncodedFrame] = []

    var frames: [H264EncodedFrame] {
        lock.withLock {
            mutableFrames
        }
    }

    func record(_ frame: H264EncodedFrame) {
        lock.withLock {
            mutableFrames.append(frame)
        }
    }
}

private enum H264TestError: Error {
    case pixelBufferCreationFailed(CVReturn)
}
