import Foundation
import SwiftProtobuf
import XCTest
@testable import LiveKitNative

final class SignalFrameCodecTests: XCTestCase {
    func testEncodesAndDecodesBinaryProtobufMessages() throws {
        let codec = SignalFrameCodec()
        var message = Google_Protobuf_Any()
        message.typeURL = "type.livekit.test/signal"
        message.value = Data([0x01, 0x02, 0x03])

        let encoded = try codec.encode(message)
        let decoded = try codec.decode(Google_Protobuf_Any.self, from: encoded)

        XCTAssertEqual(decoded, message)
    }

    func testRejectsInvalidBinaryPayload() {
        let codec = SignalFrameCodec()

        XCTAssertThrowsError(try codec.decode(Google_Protobuf_Any.self, from: Data([0xff])))
    }
}
