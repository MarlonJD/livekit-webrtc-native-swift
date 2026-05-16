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

    func testBuildsTURNAllocateRequestWithAuthenticationChallengeAttributes() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 4, count: 12))
        let message = TURNAllocateRequestFactory.makeAllocateRequest(
            relayedTransport: .udp,
            username: "relay-user",
            realm: "example.org",
            nonce: "nonce-1",
            lifetimeSeconds: 600,
            transactionID: transactionID
        )

        let decoded = try STUNMessage(decoding: try message.encoded())

        XCTAssertEqual(decoded.type, .allocateRequest)
        XCTAssertEqual(decoded.transactionID, transactionID)
        XCTAssertEqual(decoded.firstAttribute(.requestedTransport)?.requestedTransportProtocol, .udp)
        XCTAssertEqual(decoded.firstAttribute(.lifetime)?.uint32Value, 600)
        XCTAssertEqual(try decoded.firstAttribute(.username)?.stringValue, "relay-user")
        XCTAssertEqual(try decoded.firstAttribute(.realm)?.stringValue, "example.org")
        XCTAssertEqual(try decoded.firstAttribute(.nonce)?.stringValue, "nonce-1")
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

    func testDecodesXORMappedAddressFromBindingSuccessResponse() throws {
        let transactionID = try STUNTransactionID(bytes: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        let message = STUNMessage(
            type: .bindingSuccessResponse,
            transactionID: transactionID,
            attributes: [
                try .xorMappedAddressIPv4(address: "203.0.113.5", port: 54_321, transactionID: transactionID),
            ]
        )

        let decoded = try STUNMessage(decoding: try message.encoded())
        let mappedAddress = try decoded.firstAttribute(.xorMappedAddress)?.xorMappedAddressValue

        XCTAssertEqual(mappedAddress, STUNMappedAddress(address: "203.0.113.5", port: 54_321))
    }

    func testDecodesXORRelayedAddressFromTURNAllocateSuccessResponse() throws {
        let transactionID = try STUNTransactionID(bytes: [11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0])
        let message = STUNMessage(
            type: .allocateSuccessResponse,
            transactionID: transactionID,
            attributes: [
                .lifetime(seconds: 1_200),
                try .xorRelayedAddressIPv4(
                    address: "192.0.2.55",
                    port: 49_152,
                    transactionID: transactionID
                ),
            ]
        )

        let decoded = try STUNMessage(decoding: try message.encoded())
        let relayedAddress = try decoded.firstAttribute(.xorRelayedAddress)?.xorRelayedAddressValue

        XCTAssertEqual(decoded.type, .allocateSuccessResponse)
        XCTAssertEqual(decoded.firstAttribute(.lifetime)?.uint32Value, 1_200)
        XCTAssertEqual(relayedAddress, STUNMappedAddress(address: "192.0.2.55", port: 49_152))
    }

    func testRejectsInvalidXORMappedAddress() throws {
        let attribute = STUNAttribute(type: .xorMappedAddress, value: Data([0, 1, 2]))

        XCTAssertThrowsError(try attribute.xorMappedAddressValue) { error in
            XCTAssertEqual(error as? STUNError, .invalidAddressAttribute)
        }
    }

    func testValidatesRFC5769SampleRequestIntegrityAndFingerprint() throws {
        let encoded = Data(hexString: """
        00 01 00 58 21 12 a4 42 b7 e7 a7 01 bc 34 d6 86
        fa 87 df ae 80 22 00 10 53 54 55 4e 20 74 65 73
        74 20 63 6c 69 65 6e 74 00 24 00 04 6e 00 01 ff
        80 29 00 08 93 2f f9 b1 51 26 3b 36 00 06 00 09
        65 76 74 6a 3a 68 36 76 59 20 20 20 00 08 00 14
        9a ea a7 0c bf d8 cb 56 78 1e f2 b5 b2 d3 f2 49
        c1 b5 71 a2 80 28 00 04 e5 7a 3b cf
        """)
        let message = try STUNMessage(decoding: encoded)

        XCTAssertTrue(try message.validatesMessageIntegrity(key: "VOkJxbRl1RmTxUk/WvJxBt"))
        XCTAssertTrue(try message.validatesFingerprint())
    }

    func testSignedEncodingAppendsMessageIntegrityAndFingerprint() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 8, count: 12))
        let message = STUNMessage(
            type: .bindingRequest,
            transactionID: transactionID,
            attributes: [
                .username("remote:local"),
                .priority(1_864_403_327),
                .useCandidate,
            ]
        )

        let encoded = try message.encoded(
            messageIntegrityKey: "shared-secret",
            includeFingerprint: true
        )
        let decoded = try STUNMessage(decoding: encoded)

        XCTAssertEqual(decoded.firstAttribute(.messageIntegrity)?.value.count, 20)
        XCTAssertEqual(decoded.firstAttribute(.fingerprint)?.value.count, 4)
        XCTAssertTrue(try decoded.validatesMessageIntegrity(key: "shared-secret"))
        XCTAssertTrue(try decoded.validatesFingerprint())
    }

    func testDetectsTamperedMessageIntegrityAndFingerprint() throws {
        let message = STUNMessage(
            type: .bindingRequest,
            transactionID: try STUNTransactionID(bytes: Array(repeating: 3, count: 12)),
            attributes: [.username("remote:local")]
        )
        var encoded = try message.encoded(
            messageIntegrityKey: "shared-secret",
            includeFingerprint: true
        )
        encoded[24] ^= 0x01
        let decoded = try STUNMessage(decoding: encoded)

        XCTAssertFalse(try decoded.validatesMessageIntegrity(key: "shared-secret"))
        XCTAssertFalse(try decoded.validatesFingerprint())
    }
}

private extension Data {
    init(hexString: String) {
        let hexDigits = hexString.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexDigits.count / 2)

        var index = hexDigits.startIndex
        while index < hexDigits.endIndex {
            let nextIndex = hexDigits.index(index, offsetBy: 2)
            bytes.append(UInt8(hexDigits[index..<nextIndex], radix: 16)!)
            index = nextIndex
        }

        self.init(bytes)
    }
}
