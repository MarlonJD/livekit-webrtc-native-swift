import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class VP8RTPTests: XCTestCase {
    private let keyFrame = Data([0x10, 0x00, 0x00, 0x9D, 0x01, 0x2A, 0x80, 0x02, 0x68, 0x01])

    func testParsesBasicPayloadDescriptor() throws {
        let descriptor = try VP8PayloadDescriptor(payload: Data([0x10]) + keyFrame)

        XCTAssertFalse(descriptor.hasExtension)
        XCTAssertFalse(descriptor.isNonReferenceFrame)
        XCTAssertTrue(descriptor.isStartOfPartition)
        XCTAssertEqual(descriptor.partitionIndex, 0)
        XCTAssertNil(descriptor.pictureID)
        XCTAssertEqual(descriptor.headerLength, 1)
    }

    func testParsesExtendedPayloadDescriptorWithPictureAndLayerFields() throws {
        let descriptor = try VP8PayloadDescriptor(
            payload: Data([0x90, 0xF0, 0x92, 0x34, 0x56, 0xAB]) + keyFrame
        )

        XCTAssertTrue(descriptor.hasExtension)
        XCTAssertTrue(descriptor.isStartOfPartition)
        XCTAssertEqual(descriptor.pictureID, 0x1234)
        XCTAssertEqual(descriptor.tl0PicIndex, 0x56)
        XCTAssertEqual(descriptor.temporalLayerID, 2)
        XCTAssertEqual(descriptor.layerSync, true)
        XCTAssertEqual(descriptor.keyIndex, 11)
        XCTAssertEqual(descriptor.headerLength, 6)
    }

    func testRejectsInvalidPayloadDescriptor() {
        XCTAssertThrowsError(try VP8PayloadDescriptor(payload: Data())) { error in
            XCTAssertEqual(error as? VP8RTPError, .emptyPayload)
        }

        XCTAssertThrowsError(try VP8PayloadDescriptor(payload: Data([0x80]))) { error in
            XCTAssertEqual(error as? VP8RTPError, .invalidPayloadDescriptor)
        }
    }

    func testDepacketizerReturnsFrameFragment() throws {
        let packet = RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: 42,
            timestamp: 90_000,
            ssrc: 7,
            payload: Data([0x90, 0x80, 0x7F]) + keyFrame
        )

        let fragment = try VP8RTPDepacketizer().depacketize(packet)

        XCTAssertEqual(fragment.descriptor.pictureID, 127)
        XCTAssertEqual(fragment.payload, keyFrame)
        XCTAssertEqual(fragment.timestamp, 90_000)
        XCTAssertEqual(fragment.sequenceNumber, 42)
        XCTAssertEqual(fragment.ssrc, 7)
        XCTAssertTrue(fragment.marker)
    }

    func testFrameHeaderExtractsKeyFrameSize() throws {
        let header = try VP8FrameHeader(frameData: keyFrame)

        XCTAssertTrue(header.isKeyFrame)
        XCTAssertEqual(header.version, 0)
        XCTAssertTrue(header.showFrame)
        XCTAssertEqual(header.size, VP8FrameSize(width: 640, height: 360))
    }
}
