import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class TURNChannelDataTests: XCTestCase {
    func testRoundTripsFrame() throws {
        let frame = try TURNChannelDataFrame(
            channelNumber: 0x4000,
            payload: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        let encoded = try frame.encoded()
        let decoded = try TURNChannelDataFrame(decoding: encoded)

        XCTAssertEqual(encoded, Data([0x40, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(decoded, frame)
    }

    func testEncodesFourBytePaddingWithoutChangingPayloadLength() throws {
        let frame = try TURNChannelDataFrame(
            channelNumber: 0x4001,
            payload: Data([0x01, 0x02, 0x03, 0x04, 0x05])
        )

        let encoded = try frame.encoded()
        let decoded = try TURNChannelDataFrame(decoding: encoded)

        XCTAssertEqual(encoded.count, 12)
        XCTAssertEqual(encoded, Data([0x40, 0x01, 0x00, 0x05, 0x01, 0x02, 0x03, 0x04, 0x05, 0x00, 0x00, 0x00]))
        XCTAssertEqual(decoded.payload, Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    func testRejectsLowChannelNumber() throws {
        XCTAssertThrowsError(
            try TURNChannelDataFrame(channelNumber: 0x3FFF, payload: Data())
        ) { error in
            XCTAssertEqual(error as? TURNChannelDataError, .invalidChannelNumber(0x3FFF))
        }

        XCTAssertThrowsError(
            try TURNChannelDataFrame(decoding: Data([0x3F, 0xFF, 0x00, 0x00]))
        ) { error in
            XCTAssertEqual(error as? TURNChannelDataError, .invalidChannelNumber(0x3FFF))
        }
    }

    func testRejectsHighChannelNumber() throws {
        XCTAssertThrowsError(
            try TURNChannelDataFrame(channelNumber: 0x8000, payload: Data())
        ) { error in
            XCTAssertEqual(error as? TURNChannelDataError, .invalidChannelNumber(0x8000))
        }

        XCTAssertThrowsError(
            try TURNChannelDataFrame(decoding: Data([0x80, 0x00, 0x00, 0x00]))
        ) { error in
            XCTAssertEqual(error as? TURNChannelDataError, .invalidChannelNumber(0x8000))
        }
    }

    func testRejectsTruncatedHeader() throws {
        XCTAssertThrowsError(
            try TURNChannelDataFrame(decoding: Data([0x40, 0x00, 0x00]))
        ) { error in
            XCTAssertEqual(error as? TURNChannelDataError, .packetTooShort)
        }
    }

    func testRejectsLengthBiggerThanAvailableFrameBytes() throws {
        XCTAssertThrowsError(
            try TURNChannelDataFrame(decoding: Data([0x40, 0x00, 0x00, 0x04, 0xAA, 0xBB]))
        ) { error in
            XCTAssertEqual(
                error as? TURNChannelDataError,
                .invalidLength(declaredPayloadLength: 4, availableFrameBytes: 2)
            )
        }
    }

    func testDecodeFramesReturnsParsedFramesAndRemainder() throws {
        let first = try TURNChannelDataFrame(channelNumber: 0x4000, payload: Data([0x01, 0x02, 0x03]))
        let second = try TURNChannelDataFrame(channelNumber: 0x4001, payload: Data([0x04, 0x05, 0x06, 0x07]))
        let partial = Data([0x40, 0x02, 0x00])
        var stream = try first.encoded()
        stream.append(try second.encoded())
        stream.append(partial)

        let result = try TURNChannelDataFrame.decodeFrames(from: stream)

        XCTAssertEqual(result.frames, [first, second])
        XCTAssertEqual(result.remainder, partial)
    }

    func testDecodeFramesReturnsPartialFrameAsRemainder() throws {
        let complete = try TURNChannelDataFrame(channelNumber: 0x4000, payload: Data([0x01]))
        let partial = Data([0x40, 0x01, 0x00, 0x04, 0xAA])
        var stream = try complete.encoded()
        stream.append(partial)

        let result = try TURNChannelDataFrame.decodeFrames(from: stream)

        XCTAssertEqual(result.frames, [complete])
        XCTAssertEqual(result.remainder, partial)
    }
}
