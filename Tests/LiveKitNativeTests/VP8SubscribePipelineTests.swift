import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class VP8SubscribePipelineTests: XCTestCase {
    private let keyFrame = Data([0x10, 0x00, 0x00, 0x9D, 0x01, 0x2A, 0x80, 0x02, 0x68, 0x01])

    func testBuildsSinglePacketKeyFrameOnMarker() throws {
        let pipeline = VP8SubscribePipeline(expectedPayloadType: 96)
        let packet = RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: 1,
            timestamp: 90_000,
            ssrc: 99,
            payload: Data([0x90, 0x80, 0x7F]) + keyFrame
        )

        let frames = try pipeline.append(packet)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].timestamp, 90_000)
        XCTAssertEqual(frames[0].payload, keyFrame)
        XCTAssertEqual(frames[0].pictureID, 127)
        XCTAssertTrue(frames[0].isKeyFrame)
        XCTAssertEqual(frames[0].size, VP8FrameSize(width: 640, height: 360))
    }

    func testBuildsFragmentedFrameOnMarker() throws {
        let pipeline = VP8SubscribePipeline(expectedPayloadType: 96)
        let firstPayload = Data([0x90, 0x80, 0x7F]) + keyFrame.prefix(5)
        let secondPayload = Data([0x00]) + keyFrame.dropFirst(5)

        let firstPacket = RTPPacket(
            marker: false,
            payloadType: 96,
            sequenceNumber: 10,
            timestamp: 123_000,
            ssrc: 99,
            payload: firstPayload
        )
        let secondPacket = RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: 11,
            timestamp: 123_000,
            ssrc: 99,
            payload: secondPayload
        )

        XCTAssertEqual(try pipeline.append(firstPacket), [])
        let frames = try pipeline.append(secondPacket)

        XCTAssertEqual(frames.map(\.payload), [keyFrame])
        XCTAssertEqual(frames[0].pictureID, 127)
        XCTAssertEqual(frames[0].size, VP8FrameSize(width: 640, height: 360))
    }

    func testFlushReturnsPendingFrame() throws {
        let pipeline = VP8SubscribePipeline(expectedPayloadType: 96)
        let packet = RTPPacket(
            marker: false,
            payloadType: 96,
            sequenceNumber: 1,
            timestamp: 90_000,
            ssrc: 99,
            payload: Data([0x10]) + keyFrame
        )

        XCTAssertEqual(try pipeline.append(packet), [])
        XCTAssertEqual(try pipeline.flush().first?.payload, keyFrame)
    }

    func testRejectsMissingStartAndPayloadTypeMismatch() {
        let pipeline = VP8SubscribePipeline(expectedPayloadType: 96)
        let missingStart = RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: 1,
            timestamp: 90_000,
            ssrc: 99,
            payload: Data([0x00, 0x11, 0x00, 0x00])
        )
        let wrongPayloadType = RTPPacket(
            marker: true,
            payloadType: 97,
            sequenceNumber: 1,
            timestamp: 90_000,
            ssrc: 99,
            payload: Data([0x10]) + keyFrame
        )

        XCTAssertThrowsError(try pipeline.append(missingStart)) { error in
            XCTAssertEqual(error as? VP8RTPError, .missingFrameStart)
        }

        XCTAssertThrowsError(try pipeline.append(wrongPayloadType)) { error in
            XCTAssertEqual(error as? VP8RTPError, .payloadTypeMismatch(expected: 96, actual: 97))
        }
    }

    func testDetectsSequenceNumberGap() throws {
        let pipeline = VP8SubscribePipeline(expectedPayloadType: 96)
        let firstPacket = RTPPacket(
            marker: false,
            payloadType: 96,
            sequenceNumber: 1,
            timestamp: 90_000,
            ssrc: 99,
            payload: Data([0x10]) + keyFrame.prefix(5)
        )
        let secondPacket = RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: 3,
            timestamp: 90_000,
            ssrc: 99,
            payload: Data([0x00]) + keyFrame.dropFirst(5)
        )

        XCTAssertEqual(try pipeline.append(firstPacket), [])
        XCTAssertThrowsError(try pipeline.append(secondPacket)) { error in
            XCTAssertEqual(error as? VP8RTPError, .sequenceNumberGap(expected: 2, actual: 3))
        }
        XCTAssertEqual(pipeline.droppedPacketCount, 1)
    }

    func testDecodeOnlyInspectorCapturesKeyFrameMetadata() throws {
        let frame = try VP8Frame(timestamp: 90_000, payload: keyFrame, pictureID: 127)
        let inspector = VP8DecodeOnlyFrameInspector()

        let metadata = inspector.inspect(frame)

        XCTAssertEqual(metadata.timestamp, 90_000)
        XCTAssertEqual(metadata.pictureID, 127)
        XCTAssertTrue(metadata.isKeyFrame)
        XCTAssertEqual(metadata.size, VP8FrameSize(width: 640, height: 360))
        XCTAssertEqual(inspector.lastKeyFrameSize, VP8FrameSize(width: 640, height: 360))
    }
}
