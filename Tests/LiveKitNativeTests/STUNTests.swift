import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class STUNTests: XCTestCase {
    func testEncodesAndDecodesBindingRequestWithICEAttributes() throws {
        let transactionID = try STUNTransactionID(bytes: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        let message = STUNMessage(
            type: .bindingRequest,
            transactionID: transactionID,
            attributes: [
                .username("remote:local"),
                .priority(1_864_403_327),
                .useCandidate,
                .iceControlling(tieBreaker: 0x0102_0304_0506_0708),
            ]
        )

        let encoded = try message.encoded()
        let decoded = try STUNMessage(decoding: encoded)

        XCTAssertEqual(decoded.type, .bindingRequest)
        XCTAssertEqual(decoded.transactionID, transactionID)
        XCTAssertEqual(try decoded.firstAttribute(.username)?.stringValue, "remote:local")
        XCTAssertEqual(decoded.firstAttribute(.priority)?.uint32Value, 1_864_403_327)
        XCTAssertEqual(decoded.firstAttribute(.useCandidate)?.value, Data())
        XCTAssertEqual(decoded.firstAttribute(.iceControlling)?.uint64Value, 0x0102_0304_0506_0708)
    }

    func testPadsAttributesToFourByteBoundaryWithoutChangingValueLength() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 7, count: 12))
        let message = STUNMessage(type: .bindingRequest, transactionID: transactionID, attributes: [.username("abc")])

        let encoded = try message.encoded()
        let decoded = try STUNMessage(decoding: encoded)

        XCTAssertEqual(encoded.count, 28)
        XCTAssertEqual(try decoded.firstAttribute(.username)?.stringValue, "abc")
    }

    func testRejectsInvalidMagicCookie() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 1, count: 12))
        var encoded = try STUNMessage(type: .bindingRequest, transactionID: transactionID).encoded()
        encoded[4] = 0

        XCTAssertThrowsError(try STUNMessage(decoding: encoded)) { error in
            XCTAssertEqual(error as? STUNError, .invalidMagicCookie(0x0012_A442))
        }
    }

    func testRejectsInvalidAttributeLength() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 2, count: 12))
        var encoded = try STUNMessage(type: .bindingRequest, transactionID: transactionID, attributes: [.username("abc")]).encoded()
        encoded[3] = 7

        XCTAssertThrowsError(try STUNMessage(decoding: encoded)) { error in
            XCTAssertEqual(error as? STUNError, .invalidMessageLength)
        }
    }
}
