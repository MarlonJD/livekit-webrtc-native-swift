import CommonCrypto
import Foundation

package enum DTLSSRTPError: Error, Equatable, Sendable {
    case unsupportedProtectionProfile(UInt16)
    case invalidExporterByteCount(expected: Int, actual: Int)
    case invalidMasterKeyLength(expected: Int, actual: Int)
    case invalidMasterSaltLength(expected: Int, actual: Int)
    case keyDerivationIndexOutOfRange(UInt64)
    case aesOperationFailed(Int32)
    case invalidUseSRTExtensionLength
    case missingUseSRTPProtectionProfiles
    case invalidUseSRTPMKIByteCount(Int)
    case webRTCUseSRTPNegotiationUnavailable
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
    package var authenticationKeyLength: Int
    package var srtpAuthenticationTagLength: Int
    package var srtcpAuthenticationTagLength: Int

    package init(
        identifier: UInt16,
        name: String,
        masterKeyLength: Int,
        masterSaltLength: Int,
        authenticationKeyLength: Int,
        srtpAuthenticationTagLength: Int,
        srtcpAuthenticationTagLength: Int
    ) {
        self.identifier = identifier
        self.name = name
        self.masterKeyLength = masterKeyLength
        self.masterSaltLength = masterSaltLength
        self.authenticationKeyLength = authenticationKeyLength
        self.srtpAuthenticationTagLength = srtpAuthenticationTagLength
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
        authenticationKeyLength: 20,
        srtpAuthenticationTagLength: 10,
        srtcpAuthenticationTagLength: 10
    )

    package static let aes128CMHMACSHA132 = SRTPProtectionProfile(
        identifier: 0x0002,
        name: "SRTP_AES128_CM_HMAC_SHA1_32",
        masterKeyLength: 16,
        masterSaltLength: 14,
        authenticationKeyLength: 20,
        srtpAuthenticationTagLength: 4,
        srtcpAuthenticationTagLength: 10
    )
}

package struct DTLSSRTPUseSRTExtension: Equatable, Sendable {
    package static let extensionType: UInt16 = 14

    package var protectionProfiles: [SRTPProtectionProfile]
    package var mki: Data

    package init(
        protectionProfiles: [SRTPProtectionProfile] = [.aes128CMHMACSHA180],
        mki: Data = Data()
    ) throws {
        guard !protectionProfiles.isEmpty else {
            throw DTLSSRTPError.missingUseSRTPProtectionProfiles
        }
        guard mki.count <= UInt8.max else {
            throw DTLSSRTPError.invalidUseSRTPMKIByteCount(mki.count)
        }

        self.protectionProfiles = protectionProfiles
        self.mki = mki
    }

    package init(decoding data: Data) throws {
        guard data.count >= 3 else {
            throw DTLSSRTPError.invalidUseSRTExtensionLength
        }

        let profileByteCount = Int(try data.dtlsNetworkUInt16(at: 0))
        guard profileByteCount > 0, profileByteCount.isMultiple(of: 2) else {
            throw DTLSSRTPError.missingUseSRTPProtectionProfiles
        }
        guard data.count >= 2 + profileByteCount + 1 else {
            throw DTLSSRTPError.invalidUseSRTExtensionLength
        }

        var profiles: [SRTPProtectionProfile] = []
        var offset = 2
        while offset < 2 + profileByteCount {
            profiles.append(try SRTPProtectionProfile(identifier: try data.dtlsNetworkUInt16(at: offset)))
            offset += 2
        }

        let mkiByteCount = Int(data.byte(at: offset))
        let mkiStart = offset + 1
        guard data.count == mkiStart + mkiByteCount else {
            throw DTLSSRTPError.invalidUseSRTExtensionLength
        }
        let mkiStartIndex = data.index(data.startIndex, offsetBy: mkiStart)
        let mkiEndIndex = data.index(mkiStartIndex, offsetBy: mkiByteCount)

        try self.init(
            protectionProfiles: profiles,
            mki: Data(data[mkiStartIndex..<mkiEndIndex])
        )
    }

    package func encoded() throws -> Data {
        let profileByteCount = protectionProfiles.count * 2
        guard profileByteCount <= UInt16.max else {
            throw DTLSSRTPError.invalidUseSRTExtensionLength
        }
        guard mki.count <= UInt8.max else {
            throw DTLSSRTPError.invalidUseSRTPMKIByteCount(mki.count)
        }

        var data = Data()
        data.appendDTLSNetworkUInt16(UInt16(profileByteCount))
        for profile in protectionProfiles {
            data.appendDTLSNetworkUInt16(profile.identifier)
        }
        data.append(UInt8(mki.count))
        data.append(mki)
        return data
    }

    package func selectedProfile(supportedProfiles: [SRTPProtectionProfile]) -> SRTPProtectionProfile? {
        protectionProfiles.first { offered in
            supportedProfiles.contains(offered)
        }
    }
}

package struct DTLSSRTPHandshakeConfiguration: Equatable, Sendable {
    package var role: DTLSSRTPRole
    package var remoteFingerprint: DTLSSignature
    package var useSRTExtension: DTLSSRTPUseSRTExtension

    package init(
        role: DTLSSRTPRole,
        remoteFingerprint: DTLSSignature,
        useSRTExtension: DTLSSRTPUseSRTExtension? = nil
    ) throws {
        self.role = role
        self.remoteFingerprint = remoteFingerprint
        if let useSRTExtension {
            self.useSRTExtension = useSRTExtension
        } else {
            self.useSRTExtension = try DTLSSRTPUseSRTExtension()
        }
    }
}

package struct SRTPMasterKeyMaterial: Equatable, Sendable {
    package var masterKey: Data
    package var masterSalt: Data

    package init(masterKey: Data, masterSalt: Data) {
        self.masterKey = masterKey
        self.masterSalt = masterSalt
    }
}

package struct SRTPSessionKeys: Equatable, Sendable {
    package var srtpEncryptionKey: Data
    package var srtpAuthenticationKey: Data
    package var srtpSaltKey: Data
    package var srtcpEncryptionKey: Data
    package var srtcpAuthenticationKey: Data
    package var srtcpSaltKey: Data

    package init(
        masterKeyMaterial: SRTPMasterKeyMaterial,
        protectionProfile: SRTPProtectionProfile = .aes128CMHMACSHA180,
        packetIndex: UInt64 = 0,
        keyDerivationRate: UInt64 = 0
    ) throws {
        let deriver = try SRTPSessionKeyDeriver(masterKeyMaterial: masterKeyMaterial)

        self.srtpEncryptionKey = try deriver.derive(
            label: .srtpEncryption,
            byteCount: protectionProfile.masterKeyLength,
            packetIndex: packetIndex,
            keyDerivationRate: keyDerivationRate
        )
        self.srtpAuthenticationKey = try deriver.derive(
            label: .srtpAuthentication,
            byteCount: protectionProfile.authenticationKeyLength,
            packetIndex: packetIndex,
            keyDerivationRate: keyDerivationRate
        )
        self.srtpSaltKey = try deriver.derive(
            label: .srtpSalt,
            byteCount: protectionProfile.masterSaltLength,
            packetIndex: packetIndex,
            keyDerivationRate: keyDerivationRate
        )
        self.srtcpEncryptionKey = try deriver.derive(
            label: .srtcpEncryption,
            byteCount: protectionProfile.masterKeyLength,
            packetIndex: packetIndex,
            keyDerivationRate: keyDerivationRate
        )
        self.srtcpAuthenticationKey = try deriver.derive(
            label: .srtcpAuthentication,
            byteCount: protectionProfile.authenticationKeyLength,
            packetIndex: packetIndex,
            keyDerivationRate: keyDerivationRate
        )
        self.srtcpSaltKey = try deriver.derive(
            label: .srtcpSalt,
            byteCount: protectionProfile.masterSaltLength,
            packetIndex: packetIndex,
            keyDerivationRate: keyDerivationRate
        )
    }
}

package struct DTLSSRTPPacketProtectionContext: Equatable, Sendable {
    package var role: DTLSSRTPRole
    package var protectionProfile: SRTPProtectionProfile
    package var outboundRTPProtector: SRTPPacketProtector
    package var inboundRTPUnprotector: SRTPPacketUnprotector
    package var outboundRTCPProtector: SRTCPPacketProtector
    package var inboundRTCPUnprotector: SRTCPPacketUnprotector

    package init(
        keyMaterial: DTLSSRTPKeyMaterial,
        role: DTLSSRTPRole
    ) throws {
        self.role = role
        self.protectionProfile = keyMaterial.protectionProfile

        let outboundKeys = try SRTPSessionKeys(
            masterKeyMaterial: keyMaterial.localWriteMaterial(for: role),
            protectionProfile: keyMaterial.protectionProfile
        )
        let inboundKeys = try SRTPSessionKeys(
            masterKeyMaterial: keyMaterial.remoteWriteMaterial(for: role),
            protectionProfile: keyMaterial.protectionProfile
        )

        self.outboundRTPProtector = try Self.makeRTPProtector(
            keys: outboundKeys,
            protectionProfile: keyMaterial.protectionProfile
        )
        self.inboundRTPUnprotector = try SRTPPacketUnprotector(
            protector: Self.makeRTPProtector(
                keys: inboundKeys,
                protectionProfile: keyMaterial.protectionProfile
            )
        )
        self.outboundRTCPProtector = try Self.makeRTCPProtector(
            keys: outboundKeys,
            protectionProfile: keyMaterial.protectionProfile
        )
        self.inboundRTCPUnprotector = try SRTCPPacketUnprotector(
            protector: Self.makeRTCPProtector(
                keys: inboundKeys,
                protectionProfile: keyMaterial.protectionProfile
            )
        )
    }

    package func protectRTP(_ packet: RTPPacket, rolloverCounter: UInt32) throws -> SRTPProtectedPacket {
        try outboundRTPProtector.protect(packet, rolloverCounter: rolloverCounter)
    }

    package mutating func unprotectRTP(_ packet: SRTPProtectedPacket) throws -> RTPPacket {
        try inboundRTPUnprotector.unprotect(packet)
    }

    package mutating func unprotectRTP(encoded data: Data, rolloverCounter: UInt32) throws -> RTPPacket {
        try inboundRTPUnprotector.unprotect(
            encoded: data,
            rolloverCounter: rolloverCounter,
            authenticationTagLength: protectionProfile.srtpAuthenticationTagLength
        )
    }

    package func protectRTCP(_ packet: SRTCPPacket) throws -> SRTCPPacket {
        try outboundRTCPProtector.protect(packet)
    }

    package mutating func unprotectRTCP(_ packet: SRTCPPacket) throws -> SRTCPPacket {
        try inboundRTCPUnprotector.unprotect(packet)
    }

    package mutating func unprotectRTCP(encoded data: Data) throws -> SRTCPPacket {
        try inboundRTCPUnprotector.unprotect(
            encoded: data,
            authenticationTagLength: protectionProfile.srtcpAuthenticationTagLength
        )
    }

    private static func makeRTPProtector(
        keys: SRTPSessionKeys,
        protectionProfile: SRTPProtectionProfile
    ) throws -> SRTPPacketProtector {
        SRTPPacketProtector(
            cipher: try SRTPAESCounterModeCipher(
                sessionEncryptionKey: keys.srtpEncryptionKey,
                sessionSalt: keys.srtpSaltKey
            ),
            authenticator: try SRTPAuthenticator(
                authenticationKey: keys.srtpAuthenticationKey,
                tagLength: protectionProfile.srtpAuthenticationTagLength
            )
        )
    }

    private static func makeRTCPProtector(
        keys: SRTPSessionKeys,
        protectionProfile: SRTPProtectionProfile
    ) throws -> SRTCPPacketProtector {
        SRTCPPacketProtector(
            cipher: try SRTCPAESCounterModeCipher(
                sessionEncryptionKey: keys.srtcpEncryptionKey,
                sessionSalt: keys.srtcpSaltKey
            ),
            authenticator: try SRTCPAuthenticator(
                authenticationKey: keys.srtcpAuthenticationKey,
                tagLength: protectionProfile.srtcpAuthenticationTagLength
            )
        )
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

package struct DTLSSRTPHandshakeResult: Equatable, Sendable {
    package var role: DTLSSRTPRole
    package var protectionProfile: SRTPProtectionProfile
    package var exportedKeyingMaterial: Data
    package var remoteFingerprint: DTLSSignature?

    package init(
        role: DTLSSRTPRole,
        protectionProfile: SRTPProtectionProfile = .aes128CMHMACSHA180,
        exportedKeyingMaterial: Data,
        remoteFingerprint: DTLSSignature? = nil
    ) throws {
        let expectedByteCount = protectionProfile.exporterByteCount
        guard exportedKeyingMaterial.count == expectedByteCount else {
            throw DTLSSRTPError.invalidExporterByteCount(
                expected: expectedByteCount,
                actual: exportedKeyingMaterial.count
            )
        }

        self.role = role
        self.protectionProfile = protectionProfile
        self.exportedKeyingMaterial = exportedKeyingMaterial
        self.remoteFingerprint = remoteFingerprint
    }

    package func keyMaterial() throws -> DTLSSRTPKeyMaterial {
        try DTLSSRTPKeyMaterial(
            exportedKeyingMaterial: exportedKeyingMaterial,
            protectionProfile: protectionProfile
        )
    }
}

private enum SRTPSessionKeyLabel: UInt8 {
    case srtpEncryption = 0x00
    case srtpAuthentication = 0x01
    case srtpSalt = 0x02
    case srtcpEncryption = 0x03
    case srtcpAuthentication = 0x04
    case srtcpSalt = 0x05
}

private struct SRTPSessionKeyDeriver {
    private static let masterKeyLength = 16
    private static let masterSaltLength = 14
    private static let maximumDerivationIndex: UInt64 = 0xFFFF_FFFF_FFFF

    private var masterKey: Data
    private var masterSalt: Data

    init(masterKeyMaterial: SRTPMasterKeyMaterial) throws {
        guard masterKeyMaterial.masterKey.count == Self.masterKeyLength else {
            throw DTLSSRTPError.invalidMasterKeyLength(
                expected: Self.masterKeyLength,
                actual: masterKeyMaterial.masterKey.count
            )
        }
        guard masterKeyMaterial.masterSalt.count == Self.masterSaltLength else {
            throw DTLSSRTPError.invalidMasterSaltLength(
                expected: Self.masterSaltLength,
                actual: masterKeyMaterial.masterSalt.count
            )
        }

        self.masterKey = masterKeyMaterial.masterKey
        self.masterSalt = masterKeyMaterial.masterSalt
    }

    func derive(
        label: SRTPSessionKeyLabel,
        byteCount: Int,
        packetIndex: UInt64,
        keyDerivationRate: UInt64
    ) throws -> Data {
        guard byteCount > 0 else {
            return Data()
        }

        let derivationIndex = keyDerivationRate == 0 ? 0 : packetIndex / keyDerivationRate
        guard derivationIndex <= Self.maximumDerivationIndex else {
            throw DTLSSRTPError.keyDerivationIndexOutOfRange(derivationIndex)
        }

        let baseBlock = keyDerivationBaseBlock(
            label: label.rawValue,
            derivationIndex: derivationIndex
        )
        let blockCount = (byteCount + kCCBlockSizeAES128 - 1) / kCCBlockSizeAES128
        var output = Data()
        output.reserveCapacity(blockCount * kCCBlockSizeAES128)

        for blockIndex in 0..<blockCount {
            var counterBlock = baseBlock
            counterBlock[14] = UInt8((blockIndex >> 8) & 0xFF)
            counterBlock[15] = UInt8(blockIndex & 0xFF)
            output.append(try aesEncryptBlock(counterBlock))
        }

        return Data(output.prefix(byteCount))
    }

    private func keyDerivationBaseBlock(label: UInt8, derivationIndex: UInt64) -> [UInt8] {
        var keyID = [UInt8](repeating: 0, count: Self.masterSaltLength)
        keyID[7] = label
        keyID[8] = UInt8((derivationIndex >> 40) & 0xFF)
        keyID[9] = UInt8((derivationIndex >> 32) & 0xFF)
        keyID[10] = UInt8((derivationIndex >> 24) & 0xFF)
        keyID[11] = UInt8((derivationIndex >> 16) & 0xFF)
        keyID[12] = UInt8((derivationIndex >> 8) & 0xFF)
        keyID[13] = UInt8(derivationIndex & 0xFF)

        var block = Array(masterSalt)
        for index in 0..<Self.masterSaltLength {
            block[index] ^= keyID[index]
        }
        block.append(0)
        block.append(0)
        return block
    }

    private func aesEncryptBlock(_ counterBlock: [UInt8]) throws -> Data {
        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var outputLength = 0
        let status = masterKey.withUnsafeBytes { keyBytes in
            counterBlock.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        masterKey.count,
                        nil,
                        inputBytes.baseAddress,
                        counterBlock.count,
                        outputBytes.baseAddress,
                        outputBytes.count,
                        &outputLength
                    )
                }
            }
        }

        guard status == kCCSuccess, outputLength == kCCBlockSizeAES128 else {
            throw DTLSSRTPError.aesOperationFailed(status)
        }

        return Data(output)
    }
}

private extension Data {
    func slice(offset: inout Int, count: Int) -> Data {
        let start = index(startIndex, offsetBy: offset)
        let end = index(start, offsetBy: count)
        offset += count
        return Data(self[start..<end])
    }

    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func dtlsNetworkUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 1 < count else {
            throw DTLSSRTPError.invalidUseSRTExtensionLength
        }

        return UInt16(byte(at: offset)) << 8 | UInt16(byte(at: offset + 1))
    }

    mutating func appendDTLSNetworkUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
