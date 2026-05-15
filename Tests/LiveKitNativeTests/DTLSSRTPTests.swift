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
        XCTAssertEqual(profile.srtcpAuthenticationTagLength, 10)
        XCTAssertEqual(profile.exporterByteCount, 60)
        XCTAssertEqual(SRTPProtectionProfile.exporterLabel, "EXTRACTOR-dtls_srtp")
    }

    func testRejectsUnsupportedProtectionProfile() {
        XCTAssertThrowsError(try SRTPProtectionProfile(identifier: 0x9999)) { error in
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

    func testShortAuthenticationTagProfileUsesSameExporterByteCount() throws {
        let profile = try SRTPProtectionProfile(identifier: 0x0002)
        let exported = Data((0..<60).map(UInt8.init))

        let keyMaterial = try DTLSSRTPKeyMaterial(
            exportedKeyingMaterial: exported,
            protectionProfile: profile
        )

        XCTAssertEqual(profile, .aes128CMHMACSHA132)
        XCTAssertEqual(profile.srtcpAuthenticationTagLength, 4)
        XCTAssertEqual(profile.exporterByteCount, 60)
        XCTAssertEqual(keyMaterial.protectionProfile, profile)
    }
}
