import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class SRTCPTests: XCTestCase {
    func testSRTCPIndexEncodesEncryptedFlag() throws {
        let index = try SRTCPIndex(value: 42, isEncrypted: true)

        XCTAssertEqual(index.rawValue, 0x8000_002A)
        XCTAssertEqual(SRTCPIndex(rawValue: index.rawValue), index)
    }

    func testSRTCPIndexRejectsOutOfRangeValue() {
        XCTAssertThrowsError(try SRTCPIndex(value: 0x8000_0000)) { error in
            XCTAssertEqual(error as? SRTCPError, .indexOutOfRange(0x8000_0000))
        }
    }

    func testSRTCPPacketRoundTripsWithAuthenticationTag() throws {
        let packet = SRTCPPacket(
            rtcpPacket: .pictureLossIndication(
                RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
            ),
            index: try SRTCPIndex(value: 7, isEncrypted: false),
            authenticationTag: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        )

        let decoded = try SRTCPPacket(decoding: try packet.encoded())

        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded.senderSSRC, 0x0102_0304)
    }

    func testSRTCPPacketSupportsCustomAuthenticationTagLength() throws {
        let packet = SRTCPPacket(
            rtcpPacket: .receiverReport(RTCPReceiverReport(senderSSRC: 0x1020_3040)),
            index: try SRTCPIndex(value: 13),
            authenticationTag: Data([0xAA, 0xBB, 0xCC, 0xDD])
        )

        let decoded = try SRTCPPacket(decoding: try packet.encoded(), authenticationTagLength: 4)

        XCTAssertEqual(decoded, packet)
    }

    func testSRTCPPacketRejectsNegativeAuthenticationTagLength() throws {
        let encoded = try SRTCPPacket(
            rtcpPacket: .receiverReport(RTCPReceiverReport(senderSSRC: 1)),
            index: SRTCPIndex(rawValue: 1)
        ).encoded()

        XCTAssertThrowsError(try SRTCPPacket(decoding: encoded, authenticationTagLength: -1)) { error in
            XCTAssertEqual(error as? SRTCPError, .invalidAuthenticationTagLength(-1))
        }
    }

    func testSRTCPPacketRejectsLengthMismatch() throws {
        var encoded = try SRTCPPacket(
            rtcpPacket: .receiverReport(RTCPReceiverReport(senderSSRC: 1)),
            index: SRTCPIndex(rawValue: 1),
            authenticationTag: Data(repeating: 0, count: 10)
        ).encoded()
        encoded.append(0)

        XCTAssertThrowsError(try SRTCPPacket(decoding: encoded)) { error in
            XCTAssertEqual(error as? SRTCPError, .invalidLength)
        }
    }

    func testSRTCPAuthenticatorAddsAndValidatesHMACSHA1Tag() throws {
        let authenticator = try SRTCPAuthenticator(
            authenticationKey: Data("srtcp-auth-key".utf8),
            tagLength: 10
        )
        let unsigned = SRTCPPacket(
            rtcpPacket: .pictureLossIndication(
                RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
            ),
            index: try SRTCPIndex(value: 9)
        )

        let authenticated = try authenticator.authenticate(unsigned)

        XCTAssertEqual(authenticated.authenticationTag.count, 10)
        XCTAssertNoThrow(try authenticator.validate(authenticated))

        var tampered = authenticated
        tampered.index = try SRTCPIndex(value: 10)
        XCTAssertThrowsError(try authenticator.validate(tampered)) { error in
            XCTAssertEqual(error as? SRTCPError, .authenticationFailed)
        }
    }

    func testSRTCPAuthenticatorRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try SRTCPAuthenticator(authenticationKey: Data())) { error in
            XCTAssertEqual(error as? SRTCPError, .emptyAuthenticationKey)
        }
        XCTAssertThrowsError(try SRTCPAuthenticator(authenticationKey: Data([1]), tagLength: 0)) { error in
            XCTAssertEqual(error as? SRTCPError, .invalidAuthenticationTagLength(0))
        }
        XCTAssertThrowsError(try SRTCPAuthenticator(authenticationKey: Data([1]), tagLength: 21)) { error in
            XCTAssertEqual(error as? SRTCPError, .invalidAuthenticationTagLength(21))
        }
    }

    func testSRTCPReplayProtectorTracksSenderSSRCsIndependently() throws {
        let first = SRTCPPacket(
            rtcpPacket: .receiverReport(RTCPReceiverReport(senderSSRC: 11)),
            index: try SRTCPIndex(value: 20)
        )
        let second = SRTCPPacket(
            rtcpPacket: .receiverReport(RTCPReceiverReport(senderSSRC: 12)),
            index: try SRTCPIndex(value: 20)
        )
        var protector = SRTCPReplayProtector(windowSize: 4)

        XCTAssertTrue(protector.accept(first))
        XCTAssertFalse(protector.accept(first))
        XCTAssertTrue(protector.accept(second))
        XCTAssertEqual(protector.highestAcceptedIndex(for: 11), 20)
        XCTAssertEqual(protector.highestAcceptedIndex(for: 12), 20)
    }

    func testSRTCPReplayProtectorRejectsPacketsOutsideWindow() throws {
        var protector = SRTCPReplayProtector(windowSize: 4)

        XCTAssertTrue(protector.accept(senderSSRC: 1, index: 10))
        XCTAssertTrue(protector.accept(senderSSRC: 1, index: 14))
        XCTAssertFalse(protector.accept(senderSSRC: 1, index: 10))
        XCTAssertTrue(protector.accept(senderSSRC: 1, index: 13))
    }

    func testSRTCPAESCipherEncryptsRTCPPayloadAndTogglesFlag() throws {
        let cipher = try srtcpCipher()
        let original = try pliPacket(index: 7)

        let encrypted = try cipher.encrypt(original)
        let decrypted = try cipher.decrypt(encrypted)

        XCTAssertTrue(encrypted.index.isEncrypted)
        XCTAssertNotEqual(encrypted.rtcpPacket, original.rtcpPacket)
        XCTAssertEqual(encrypted.senderSSRC, original.senderSSRC)
        XCTAssertFalse(decrypted.index.isEncrypted)
        XCTAssertEqual(decrypted, original)
    }

    func testSRTCPPacketProtectorEncryptsAuthenticatesAndDecrypts() throws {
        let protector = try srtcpPacketProtector()
        let original = try pliPacket(index: 9)

        let protected = try protector.protect(original)
        let decoded = try protector.unprotect(encoded: try protected.encoded())

        XCTAssertTrue(protected.index.isEncrypted)
        XCTAssertEqual(protected.authenticationTag.count, SRTCPPacket.defaultAuthenticationTagLength)
        XCTAssertEqual(decoded, original)
    }

    func testSRTCPPacketProtectorRejectsTamperedEncryptedPayload() throws {
        let protector = try srtcpPacketProtector()
        let protected = try protector.protect(try pliPacket(index: 9))
        var encoded = try protected.encoded()
        encoded[encoded.index(encoded.startIndex, offsetBy: 9)] ^= 0xFF
        let tampered = try SRTCPPacket(decoding: encoded)

        XCTAssertThrowsError(try protector.unprotect(tampered)) { error in
            XCTAssertEqual(error as? SRTCPError, .authenticationFailed)
        }
    }

    func testSRTCPPacketUnprotectorRejectsReplay() throws {
        let protector = try srtcpPacketProtector()
        let protected = try protector.protect(try pliPacket(index: 9))
        var unprotector = SRTCPPacketUnprotector(protector: protector)

        XCTAssertEqual(try unprotector.unprotect(protected), try pliPacket(index: 9))
        XCTAssertThrowsError(try unprotector.unprotect(protected)) { error in
            XCTAssertEqual(error as? SRTCPError, .replayedPacket)
        }
    }

    private func pliPacket(index: UInt32) throws -> SRTCPPacket {
        SRTCPPacket(
            rtcpPacket: .pictureLossIndication(
                RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
            ),
            index: try SRTCPIndex(value: index)
        )
    }

    private func srtcpCipher() throws -> SRTCPAESCounterModeCipher {
        try SRTCPAESCounterModeCipher(
            sessionEncryptionKey: Data((0..<16).map { UInt8($0 + 3) }),
            sessionSalt: Data((0..<14).map { UInt8($0 + 19) })
        )
    }

    private func srtcpPacketProtector() throws -> SRTCPPacketProtector {
        SRTCPPacketProtector(
            cipher: try srtcpCipher(),
            authenticator: try SRTCPAuthenticator(authenticationKey: Data("srtcp-packet-auth-key".utf8))
        )
    }
}
