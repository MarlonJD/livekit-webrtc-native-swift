import Foundation

package enum DTLSSRTPError: Error, Equatable, Sendable {
    case unsupportedProtectionProfile(UInt16)
    case invalidExporterByteCount(expected: Int, actual: Int)
}

package enum DTLSSRTPRole: Equatable, Sendable {
    case client
    case server
}

package struct SRTPProtectionProfile: Equatable, Sendable {
    package static let exporterLabel = "EXTRACTOR-dtls_srtp"

    package var identifier: UInt16
    package var name: String
    package var masterKeyLength: Int
    package var masterSaltLength: Int
    package var srtcpAuthenticationTagLength: Int

    package init(
        identifier: UInt16,
        name: String,
        masterKeyLength: Int,
        masterSaltLength: Int,
        srtcpAuthenticationTagLength: Int
    ) {
        self.identifier = identifier
        self.name = name
        self.masterKeyLength = masterKeyLength
        self.masterSaltLength = masterSaltLength
        self.srtcpAuthenticationTagLength = srtcpAuthenticationTagLength
    }

    package init(identifier: UInt16) throws {
        switch identifier {
        case Self.aes128CMHMACSHA180.identifier:
            self = .aes128CMHMACSHA180
        case Self.aes128CMHMACSHA132.identifier:
            self = .aes128CMHMACSHA132
        default:
            throw DTLSSRTPError.unsupportedProtectionProfile(identifier)
        }
    }

    package var exporterByteCount: Int {
        2 * masterKeyLength + 2 * masterSaltLength
    }

    package static let aes128CMHMACSHA180 = SRTPProtectionProfile(
        identifier: 0x0001,
        name: "SRTP_AES128_CM_HMAC_SHA1_80",
        masterKeyLength: 16,
        masterSaltLength: 14,
        srtcpAuthenticationTagLength: 10
    )

    package static let aes128CMHMACSHA132 = SRTPProtectionProfile(
        identifier: 0x0002,
        name: "SRTP_AES128_CM_HMAC_SHA1_32",
        masterKeyLength: 16,
        masterSaltLength: 14,
        srtcpAuthenticationTagLength: 4
    )
}

package struct SRTPMasterKeyMaterial: Equatable, Sendable {
    package var masterKey: Data
    package var masterSalt: Data

    package init(masterKey: Data, masterSalt: Data) {
        self.masterKey = masterKey
        self.masterSalt = masterSalt
    }
}

package struct DTLSSRTPKeyMaterial: Equatable, Sendable {
    package var protectionProfile: SRTPProtectionProfile
    package var clientWrite: SRTPMasterKeyMaterial
    package var serverWrite: SRTPMasterKeyMaterial

    package init(
        protectionProfile: SRTPProtectionProfile,
        clientWrite: SRTPMasterKeyMaterial,
        serverWrite: SRTPMasterKeyMaterial
    ) {
        self.protectionProfile = protectionProfile
        self.clientWrite = clientWrite
        self.serverWrite = serverWrite
    }

    package init(
        exportedKeyingMaterial: Data,
        protectionProfile: SRTPProtectionProfile = .aes128CMHMACSHA180
    ) throws {
        let expected = protectionProfile.exporterByteCount
        guard exportedKeyingMaterial.count == expected else {
            throw DTLSSRTPError.invalidExporterByteCount(
                expected: expected,
                actual: exportedKeyingMaterial.count
            )
        }

        var offset = 0
        let clientWriteMasterKey = exportedKeyingMaterial.slice(offset: &offset, count: protectionProfile.masterKeyLength)
        let serverWriteMasterKey = exportedKeyingMaterial.slice(offset: &offset, count: protectionProfile.masterKeyLength)
        let clientWriteMasterSalt = exportedKeyingMaterial.slice(offset: &offset, count: protectionProfile.masterSaltLength)
        let serverWriteMasterSalt = exportedKeyingMaterial.slice(offset: &offset, count: protectionProfile.masterSaltLength)

        self.init(
            protectionProfile: protectionProfile,
            clientWrite: SRTPMasterKeyMaterial(
                masterKey: clientWriteMasterKey,
                masterSalt: clientWriteMasterSalt
            ),
            serverWrite: SRTPMasterKeyMaterial(
                masterKey: serverWriteMasterKey,
                masterSalt: serverWriteMasterSalt
            )
        )
    }

    package func localWriteMaterial(for role: DTLSSRTPRole) -> SRTPMasterKeyMaterial {
        switch role {
        case .client:
            return clientWrite
        case .server:
            return serverWrite
        }
    }

    package func remoteWriteMaterial(for role: DTLSSRTPRole) -> SRTPMasterKeyMaterial {
        switch role {
        case .client:
            return serverWrite
        case .server:
            return clientWrite
        }
    }
}

private extension Data {
    func slice(offset: inout Int, count: Int) -> Data {
        let start = index(startIndex, offsetBy: offset)
        let end = index(start, offsetBy: count)
        offset += count
        return Data(self[start..<end])
    }
}
