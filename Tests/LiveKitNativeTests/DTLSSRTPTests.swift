import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class DTLSSRTPTests: XCTestCase {
    func testProtectionProfileMetadataMatchesWebRTCDefaults() throws {
        let profile = try SRTPProtectionProfile(identifier: 0x0001)

        XCTAssertEqual(profile, .aes128CMHMACSHA180)
        XCTAssertEqual(profile.name, "SRTP_AES128_CM_HMAC_SHA1_80")
        XCTAssertEqual(profile.masterKeyLength, 16)
        XCTAssertEqual(profile.masterSaltLength, 14)
        XCTAssertEqual(profile.authenticationKeyLength, 20)
        XCTAssertEqual(profile.srtpAuthenticationTagLength, 10)
        XCTAssertEqual(profile.srtcpAuthenticationTagLength, 10)
        XCTAssertEqual(profile.exporterByteCount, 60)
        XCTAssertEqual(SRTPProtectionProfile.exporterLabel, "EXTRACTOR-dtls_srtp")
    }

    func testRejectsUnsupportedProtectionProfile() {
        XCTAssertThrowsError(try SRTPProtectionProfile(identifier: 0x9999)) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .unsupportedProtectionProfile(0x9999))
        }
    }

    func testUseSRTExtensionEncodesAndDecodesProtectionProfilesAndMKI() throws {
        let extensionData = try DTLSSRTPUseSRTExtension(
            protectionProfiles: [.aes128CMHMACSHA180, .aes128CMHMACSHA132],
            mki: Data([0xCA, 0xFE])
        )

        let encoded = try extensionData.encoded()
        let decoded = try DTLSSRTPUseSRTExtension(decoding: encoded)
        let prefixed = Data([0xFF]) + encoded
        let sliced = prefixed[prefixed.index(after: prefixed.startIndex)..<prefixed.endIndex]

        XCTAssertEqual(DTLSSRTPUseSRTExtension.extensionType, 14)
        XCTAssertEqual(encoded, Data([0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x02, 0xCA, 0xFE]))
        XCTAssertEqual(decoded, extensionData)
        XCTAssertEqual(try DTLSSRTPUseSRTExtension(decoding: sliced), extensionData)
    }

    func testUseSRTExtensionSelectsFirstSupportedProtectionProfile() throws {
        let extensionData = try DTLSSRTPUseSRTExtension(
            protectionProfiles: [.aes128CMHMACSHA132, .aes128CMHMACSHA180]
        )

        XCTAssertEqual(
            extensionData.selectedProfile(supportedProfiles: [.aes128CMHMACSHA180]),
            .aes128CMHMACSHA180
        )
        XCTAssertNil(extensionData.selectedProfile(supportedProfiles: []))
    }

    func testUseSRTExtensionRejectsMalformedPayloads() {
        XCTAssertThrowsError(try DTLSSRTPUseSRTExtension(protectionProfiles: [])) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .missingUseSRTPProtectionProfiles)
        }

        XCTAssertThrowsError(try DTLSSRTPUseSRTExtension(decoding: Data([0x00, 0x02, 0x00]))) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidUseSRTExtensionLength)
        }

        XCTAssertThrowsError(try DTLSSRTPUseSRTExtension(decoding: Data([0x00, 0x02, 0x99, 0x99, 0x00]))) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .unsupportedProtectionProfile(0x9999))
        }
    }

    func testSplitsExporterMaterialIntoClientAndServerKeysAndSalts() throws {
        let exported = Data((0..<60).map(UInt8.init))

        let keyMaterial = try DTLSSRTPKeyMaterial(exportedKeyingMaterial: exported)

        XCTAssertEqual(keyMaterial.clientWrite.masterKey, Data(0..<16))
        XCTAssertEqual(keyMaterial.serverWrite.masterKey, Data(16..<32))
        XCTAssertEqual(keyMaterial.clientWrite.masterSalt, Data(32..<46))
        XCTAssertEqual(keyMaterial.serverWrite.masterSalt, Data(46..<60))
    }

    func testRejectsInvalidExporterMaterialLength() {
        XCTAssertThrowsError(
            try DTLSSRTPKeyMaterial(exportedKeyingMaterial: Data(repeating: 0, count: 59))
        ) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidExporterByteCount(expected: 60, actual: 59))
        }
    }

    func testMapsLocalAndRemoteMaterialFromDTLSRole() throws {
        let exported = Data((0..<60).map(UInt8.init))
        let keyMaterial = try DTLSSRTPKeyMaterial(exportedKeyingMaterial: exported)

        XCTAssertEqual(keyMaterial.localWriteMaterial(for: .client), keyMaterial.clientWrite)
        XCTAssertEqual(keyMaterial.remoteWriteMaterial(for: .client), keyMaterial.serverWrite)
        XCTAssertEqual(keyMaterial.localWriteMaterial(for: .server), keyMaterial.serverWrite)
        XCTAssertEqual(keyMaterial.remoteWriteMaterial(for: .server), keyMaterial.clientWrite)
    }

    func testHandshakeResultCarriesExporterMaterialAndRemoteFingerprint() throws {
        let exported = Data((0..<60).map(UInt8.init))
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")

        let result = try DTLSSRTPHandshakeResult(
            role: .client,
            exportedKeyingMaterial: exported,
            remoteFingerprint: fingerprint
        )
        let keyMaterial = try result.keyMaterial()

        XCTAssertEqual(result.role, .client)
        XCTAssertEqual(result.remoteFingerprint, fingerprint)
        XCTAssertEqual(keyMaterial.clientWrite.masterKey, Data(0..<16))
        XCTAssertEqual(keyMaterial.serverWrite.masterSalt, Data(46..<60))
    }

    func testHandshakeResultRejectsInvalidExporterLength() {
        XCTAssertThrowsError(
            try DTLSSRTPHandshakeResult(
                role: .server,
                exportedKeyingMaterial: Data(repeating: 0, count: 59)
            )
        ) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidExporterByteCount(expected: 60, actual: 59))
        }
    }

    func testUnavailableAppleDTLSSRTPHandshakerFailsExplicitly() async throws {
        let handshaker = UnavailableAppleDTLSSRTPHandshaker()
        let configuration = try DTLSSRTPHandshakeConfiguration(
            role: .client,
            remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        )

        do {
            _ = try await handshaker.performHandshake(
                configuration: configuration,
                transport: NoopDTLSDatagramTransport()
            )
            XCTFail("Expected unavailable Apple DTLS-SRTP handshaker failure.")
        } catch {
            XCTAssertEqual(error as? DTLSSRTPError, .webRTCUseSRTPNegotiationUnavailable)
        }
    }

    func testShortAuthenticationTagProfileUsesSameExporterByteCount() throws {
        let profile = try SRTPProtectionProfile(identifier: 0x0002)
        let exported = Data((0..<60).map(UInt8.init))

        let keyMaterial = try DTLSSRTPKeyMaterial(
            exportedKeyingMaterial: exported,
            protectionProfile: profile
        )

        XCTAssertEqual(profile, .aes128CMHMACSHA132)
        XCTAssertEqual(profile.srtpAuthenticationTagLength, 4)
        XCTAssertEqual(profile.srtcpAuthenticationTagLength, 10)
        XCTAssertEqual(profile.exporterByteCount, 60)
        XCTAssertEqual(keyMaterial.protectionProfile, profile)
    }

    func testDerivesSessionKeysFromRFC3711Vector() throws {
        let master = SRTPMasterKeyMaterial(
            masterKey: try Data(hex: "E1F97A0D3E018BE0D64FA32C06DE4139"),
            masterSalt: try Data(hex: "0EC675AD498AFEEBB6960B3AABE6")
        )

        let keys = try SRTPSessionKeys(masterKeyMaterial: master)

        XCTAssertEqual(keys.srtpEncryptionKey, try Data(hex: "C61E7A93744F39EE10734AFE3FF7A087"))
        XCTAssertEqual(keys.srtpSaltKey, try Data(hex: "30CBBC08863D8C85D49DB34A9AE1"))
        XCTAssertEqual(keys.srtpAuthenticationKey, try Data(hex: "CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4"))
        XCTAssertNotEqual(keys.srtcpEncryptionKey, keys.srtpEncryptionKey)
        XCTAssertNotEqual(keys.srtcpAuthenticationKey, keys.srtpAuthenticationKey)
        XCTAssertNotEqual(keys.srtcpSaltKey, keys.srtpSaltKey)
    }

    func testRejectsInvalidMasterKeyMaterialForSessionDerivation() {
        let invalidKey = SRTPMasterKeyMaterial(
            masterKey: Data(repeating: 0, count: 15),
            masterSalt: Data(repeating: 0, count: 14)
        )
        XCTAssertThrowsError(try SRTPSessionKeys(masterKeyMaterial: invalidKey)) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidMasterKeyLength(expected: 16, actual: 15))
        }

        let invalidSalt = SRTPMasterKeyMaterial(
            masterKey: Data(repeating: 0, count: 16),
            masterSalt: Data(repeating: 0, count: 13)
        )
        XCTAssertThrowsError(try SRTPSessionKeys(masterKeyMaterial: invalidSalt)) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidMasterSaltLength(expected: 14, actual: 13))
        }
    }

    func testPacketProtectionContextMapsClientAndServerDirections() throws {
        let exported = Data((0..<60).map(UInt8.init))
        let keyMaterial = try DTLSSRTPKeyMaterial(exportedKeyingMaterial: exported)
        var client = try DTLSSRTPPacketProtectionContext(keyMaterial: keyMaterial, role: .client)
        var server = try DTLSSRTPPacketProtectionContext(keyMaterial: keyMaterial, role: .server)
        let rtp = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 17,
            timestamp: 9_000,
            ssrc: 0x1122_3344,
            payload: Data((0..<64).map(UInt8.init))
        )

        let protectedRTP = try client.protectRTP(rtp, rolloverCounter: 0)
        let decodedRTP = try server.unprotectRTP(encoded: protectedRTP.encoded(), rolloverCounter: 0)

        XCTAssertNotEqual(protectedRTP.rtpPacket.payload, rtp.payload)
        XCTAssertEqual(protectedRTP.authenticationTag.count, 10)
        XCTAssertEqual(decodedRTP, rtp)
        XCTAssertThrowsError(try server.unprotectRTP(protectedRTP)) { error in
            XCTAssertEqual(error as? SRTPError, .replayedPacket)
        }

        let rtcp = try pliPacket(index: 3)
        let protectedRTCP = try server.protectRTCP(rtcp)
        let decodedRTCP = try client.unprotectRTCP(encoded: try protectedRTCP.encoded())

        XCTAssertTrue(protectedRTCP.index.isEncrypted)
        XCTAssertEqual(protectedRTCP.authenticationTag.count, 10)
        XCTAssertEqual(decodedRTCP, rtcp)
    }

    func testPacketProtectionContextUsesShortSRTPTagProfile() throws {
        let exported = Data((0..<60).map(UInt8.init))
        let keyMaterial = try DTLSSRTPKeyMaterial(
            exportedKeyingMaterial: exported,
            protectionProfile: .aes128CMHMACSHA132
        )
        var server = try DTLSSRTPPacketProtectionContext(keyMaterial: keyMaterial, role: .server)
        let client = try DTLSSRTPPacketProtectionContext(keyMaterial: keyMaterial, role: .client)
        let rtp = RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: 21,
            timestamp: 12_000,
            ssrc: 0x5566_7788,
            payload: Data([0x01, 0x02, 0x03])
        )

        let protectedRTP = try client.protectRTP(rtp, rolloverCounter: 0)
        let protectedRTCP = try client.protectRTCP(try pliPacket(index: 4))

        XCTAssertEqual(protectedRTP.authenticationTag.count, 4)
        XCTAssertEqual(try server.unprotectRTP(encoded: protectedRTP.encoded(), rolloverCounter: 0), rtp)
        XCTAssertEqual(protectedRTCP.authenticationTag.count, 10)
    }

    private func pliPacket(index: UInt32) throws -> SRTCPPacket {
        SRTCPPacket(
            rtcpPacket: .pictureLossIndication(
                RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
            ),
            index: try SRTCPIndex(value: index)
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

private struct NoopDTLSDatagramTransport: MediaDatagramTransport {
    func send(_ datagram: Data) async throws {}

    func receive() async throws -> Data {
        Data()
    }
}
