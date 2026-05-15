import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class SRTPTests: XCTestCase {
    func testSequenceNumberExtenderTracksMonotonicPackets() {
        var extender = RTPSequenceNumberExtender()

        XCTAssertEqual(extender.extend(10), 10)
        XCTAssertEqual(extender.extend(11), 11)
        XCTAssertEqual(extender.highestSequenceNumber, 11)
    }

    func testSequenceNumberExtenderHandlesForwardWrap() {
        var extender = RTPSequenceNumberExtender()

        XCTAssertEqual(extender.extend(65_534), 65_534)
        XCTAssertEqual(extender.extend(65_535), 65_535)
        XCTAssertEqual(extender.extend(0), 65_536)
        XCTAssertEqual(extender.extend(1), 65_537)
        XCTAssertEqual(extender.highestSequenceNumber, 65_537)
    }

    func testSequenceNumberExtenderMapsLatePacketToPreviousCycle() {
        var extender = RTPSequenceNumberExtender()

        XCTAssertEqual(extender.extend(65_535), 65_535)
        XCTAssertEqual(extender.extend(0), 65_536)
        XCTAssertEqual(extender.extend(65_534), 65_534)
        XCTAssertEqual(extender.highestSequenceNumber, 65_536)
    }

    func testReplayWindowAcceptsOutOfOrderPacketsInsideWindow() {
        var window = SRTPReplayWindow(size: 8)

        XCTAssertTrue(window.accept(10))
        XCTAssertTrue(window.accept(12))
        XCTAssertTrue(window.accept(11))
        XCTAssertFalse(window.accept(11))
        XCTAssertEqual(window.highestAcceptedIndex, 12)
    }

    func testReplayWindowRejectsPacketsOutsideWindow() {
        var window = SRTPReplayWindow(size: 4)

        XCTAssertTrue(window.accept(10))
        XCTAssertTrue(window.accept(14))
        XCTAssertFalse(window.accept(10))
        XCTAssertFalse(window.canAccept(10))
    }

    func testReplayProtectorTracksSSRCsIndependently() {
        var protector = SRTPReplayProtector(windowSize: 8)

        XCTAssertTrue(protector.accept(packet(sequenceNumber: 7, ssrc: 1)))
        XCTAssertFalse(protector.accept(packet(sequenceNumber: 7, ssrc: 1)))
        XCTAssertTrue(protector.accept(packet(sequenceNumber: 7, ssrc: 2)))
        XCTAssertEqual(protector.highestAcceptedIndex(for: 1), 7)
        XCTAssertEqual(protector.highestAcceptedIndex(for: 2), 7)
    }

    func testReplayProtectorHandlesRTPSequenceWrap() {
        var protector = SRTPReplayProtector(windowSize: 8)

        XCTAssertTrue(protector.accept(packet(sequenceNumber: 65_535, ssrc: 99)))
        XCTAssertTrue(protector.accept(packet(sequenceNumber: 0, ssrc: 99)))
        XCTAssertFalse(protector.accept(packet(sequenceNumber: 65_535, ssrc: 99)))
        XCTAssertEqual(protector.highestAcceptedIndex(for: 99), 65_536)
    }

    func testAESCounterModeInitializationVectorMatchesRFC3711Layout() throws {
        let cipher = try SRTPAESCounterModeCipher(
            sessionEncryptionKey: try Data(hex: "2B7E151628AED2A6ABF7158809CF4F3C"),
            sessionSalt: try Data(hex: "F0F1F2F3F4F5F6F7F8F9FAFBFCFD")
        )

        XCTAssertEqual(
            cipher.initializationVector(ssrc: 0, rolloverCounter: 0, sequenceNumber: 0),
            try Data(hex: "F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000")
        )
        XCTAssertEqual(
            cipher.initializationVector(ssrc: 0x1122_3344, rolloverCounter: 0x5566_7788, sequenceNumber: 0x99AA),
            try Data(hex: "F0F1F2F3E5D7C5B3AD9F8D7365570000")
        )
    }

    func testAESCounterModeKeystreamMatchesRFC3711B2FirstBlocks() throws {
        let cipher = try SRTPAESCounterModeCipher(
            sessionEncryptionKey: try Data(hex: "2B7E151628AED2A6ABF7158809CF4F3C"),
            sessionSalt: try Data(hex: "F0F1F2F3F4F5F6F7F8F9FAFBFCFD")
        )
        let encrypted = try cipher.encryptPayload(
            Data(repeating: 0, count: 48),
            ssrc: 0,
            rolloverCounter: 0,
            sequenceNumber: 0
        )

        XCTAssertEqual(
            encrypted,
            try Data(hex: """
            E03EAD0935C95E80E166B16DD92B4EB4
            D23513162B02D0F72A43A2FE4A5F97AB
            41E95B3BB0A2E8DD477901E4FCA894C0
            """)
        )
    }

    func testAESCounterModeEncryptDecryptRoundTripsPayloadOnly() throws {
        let cipher = try SRTPAESCounterModeCipher(
            sessionEncryptionKey: Data((0..<16).map(UInt8.init)),
            sessionSalt: Data((0..<14).map { UInt8($0 + 20) })
        )
        let original = packet(sequenceNumber: 8, ssrc: 0x1122_3344)

        let encrypted = try cipher.encrypt(original, rolloverCounter: 3)
        let decrypted = try cipher.decrypt(encrypted, rolloverCounter: 3)

        XCTAssertNotEqual(encrypted.payload, original.payload)
        XCTAssertEqual(decrypted, original)
        XCTAssertEqual(encrypted.sequenceNumber, original.sequenceNumber)
        XCTAssertEqual(encrypted.timestamp, original.timestamp)
        XCTAssertEqual(encrypted.ssrc, original.ssrc)
    }

    func testAESCounterModeRejectsInvalidConfigurationAndOversizedPayload() throws {
        XCTAssertThrowsError(
            try SRTPAESCounterModeCipher(sessionEncryptionKey: Data(repeating: 0, count: 15), sessionSalt: Data(repeating: 0, count: 14))
        ) { error in
            XCTAssertEqual(error as? SRTPError, .invalidSessionEncryptionKeyLength(15))
        }
        XCTAssertThrowsError(
            try SRTPAESCounterModeCipher(sessionEncryptionKey: Data(repeating: 0, count: 16), sessionSalt: Data(repeating: 0, count: 13))
        ) { error in
            XCTAssertEqual(error as? SRTPError, .invalidSessionSaltLength(13))
        }

        let cipher = try SRTPAESCounterModeCipher(
            sessionEncryptionKey: Data(repeating: 0, count: 16),
            sessionSalt: Data(repeating: 0, count: 14)
        )
        let tooLarge = Data(repeating: 0, count: SRTPAESCounterModeCipher.maximumKeystreamBlocks * 16 + 1)

        XCTAssertThrowsError(
            try cipher.encryptPayload(tooLarge, ssrc: 1, rolloverCounter: 0, sequenceNumber: 0)
        ) { error in
            XCTAssertEqual(error as? SRTPError, .payloadTooLarge(tooLarge.count))
        }
    }

    func testProtectedPacketEncodingKeepsRolloverCounterOutOfWireBytes() throws {
        let protected = SRTPProtectedPacket(
            rtpPacket: packet(sequenceNumber: 8, ssrc: 1),
            rolloverCounter: 3,
            authenticationTag: Data(repeating: 0xAA, count: SRTPProtectedPacket.defaultAuthenticationTagLength)
        )

        let encoded = protected.encoded()
        let decoded = try SRTPProtectedPacket(decoding: encoded, rolloverCounter: 3)

        XCTAssertEqual(decoded, protected)
        XCTAssertEqual(encoded.count, packet(sequenceNumber: 8, ssrc: 1).encoded().count + SRTPProtectedPacket.defaultAuthenticationTagLength)
    }

    func testAuthenticatorAppendsAndValidatesAuthenticationTag() throws {
        let authenticator = try SRTPAuthenticator(authenticationKey: Data("srtp-auth-key".utf8))

        let authenticated = try authenticator.authenticate(
            packet(sequenceNumber: 8, ssrc: 1),
            rolloverCounter: 0
        )
        let decoded = try SRTPProtectedPacket(decoding: authenticated.encoded(), rolloverCounter: 0)

        XCTAssertEqual(authenticated.authenticationTag.count, SRTPProtectedPacket.defaultAuthenticationTagLength)
        XCTAssertNoThrow(try authenticator.validate(decoded))
    }

    func testAuthenticatorRejectsTamperedPayload() throws {
        let authenticator = try SRTPAuthenticator(authenticationKey: Data("srtp-auth-key".utf8))
        let authenticated = try authenticator.authenticate(
            packet(sequenceNumber: 8, ssrc: 1),
            rolloverCounter: 0
        )
        var tamperedPacket = authenticated.rtpPacket
        tamperedPacket.payload[0] = 0xFF
        let tampered = SRTPProtectedPacket(
            rtpPacket: tamperedPacket,
            rolloverCounter: authenticated.rolloverCounter,
            authenticationTag: authenticated.authenticationTag
        )

        XCTAssertThrowsError(try authenticator.validate(tampered)) { error in
            XCTAssertEqual(error as? SRTPError, .authenticationFailed)
        }
    }

    func testAuthenticatorIncludesRolloverCounterInAuthenticationInput() throws {
        let authenticator = try SRTPAuthenticator(authenticationKey: Data("srtp-auth-key".utf8))
        let rtpPacket = packet(sequenceNumber: 8, ssrc: 1)

        let rolloverZero = try authenticator.authenticate(rtpPacket, rolloverCounter: 0)
        let rolloverOne = try authenticator.authenticate(rtpPacket, rolloverCounter: 1)

        XCTAssertNotEqual(rolloverZero.authenticationTag, rolloverOne.authenticationTag)
    }

    func testAuthenticatorRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try SRTPAuthenticator(authenticationKey: Data())) { error in
            XCTAssertEqual(error as? SRTPError, .emptyAuthenticationKey)
        }
        XCTAssertThrowsError(try SRTPAuthenticator(authenticationKey: Data([1]), tagLength: 0)) { error in
            XCTAssertEqual(error as? SRTPError, .invalidAuthenticationTagLength(0))
        }
    }

    func testPacketProtectorEncryptsAuthenticatesAndDecrypts() throws {
        let protector = try packetProtector()
        let original = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 9,
            timestamp: 4_000,
            ssrc: 0x1122_3344,
            payload: Data((0..<96).map(UInt8.init))
        )

        let protected = try protector.protect(original, rolloverCounter: 2)
        let decrypted = try protector.unprotect(protected)
        let decoded = try protector.unprotect(encoded: protected.encoded(), rolloverCounter: 2)

        XCTAssertNotEqual(protected.rtpPacket.payload, original.payload)
        XCTAssertEqual(protected.authenticationTag.count, SRTPProtectedPacket.defaultAuthenticationTagLength)
        XCTAssertEqual(decrypted, original)
        XCTAssertEqual(decoded, original)
    }

    func testPacketProtectorRejectsTamperedProtectedPacket() throws {
        let protector = try packetProtector()
        let protected = try protector.protect(packet(sequenceNumber: 9, ssrc: 1), rolloverCounter: 0)
        var tamperedPacket = protected.rtpPacket
        tamperedPacket.payload[0] ^= 0xFF
        let tampered = SRTPProtectedPacket(
            rtpPacket: tamperedPacket,
            rolloverCounter: protected.rolloverCounter,
            authenticationTag: protected.authenticationTag
        )

        XCTAssertThrowsError(try protector.unprotect(tampered)) { error in
            XCTAssertEqual(error as? SRTPError, .authenticationFailed)
        }
    }

    func testPacketUnprotectorRejectsReplayAfterSuccessfulAuthentication() throws {
        let protector = try packetProtector()
        let protected = try protector.protect(packet(sequenceNumber: 9, ssrc: 1), rolloverCounter: 0)
        var unprotector = SRTPPacketUnprotector(protector: protector)

        XCTAssertEqual(try unprotector.unprotect(protected), packet(sequenceNumber: 9, ssrc: 1))
        XCTAssertThrowsError(try unprotector.unprotect(protected)) { error in
            XCTAssertEqual(error as? SRTPError, .replayedPacket)
        }
    }

    private func packet(sequenceNumber: UInt16, ssrc: UInt32) -> RTPPacket {
        RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: sequenceNumber,
            timestamp: 1_000,
            ssrc: ssrc,
            payload: Data([0x01])
        )
    }

    private func packetProtector() throws -> SRTPPacketProtector {
        SRTPPacketProtector(
            cipher: try SRTPAESCounterModeCipher(
                sessionEncryptionKey: Data((0..<16).map { UInt8($0 + 1) }),
                sessionSalt: Data((0..<14).map { UInt8($0 + 17) })
            ),
            authenticator: try SRTPAuthenticator(authenticationKey: Data("srtp-packet-auth-key".utf8))
        )
    }
}

private extension Data {
    init(hex: String) throws {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else {
            throw HexError.invalidLength
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else {
                throw HexError.invalidByte
            }
            bytes.append(byte)
            index = nextIndex
        }

        self = Data(bytes)
    }
}

private enum HexError: Error {
    case invalidLength
    case invalidByte
}
