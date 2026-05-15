import CommonCrypto
import CryptoKit
import Foundation

package struct RTPSequenceNumberExtender: Equatable, Sendable {
    private var highestExtendedSequenceNumber: UInt64?

    package init() {}

    package var highestSequenceNumber: UInt64? {
        highestExtendedSequenceNumber
    }

    package mutating func extend(_ sequenceNumber: UInt16) -> UInt64 {
        guard let highestExtendedSequenceNumber else {
            let extended = UInt64(sequenceNumber)
            self.highestExtendedSequenceNumber = extended
            return extended
        }

        let highestLowBits = UInt16(highestExtendedSequenceNumber & 0xFFFF)
        var cycle = highestExtendedSequenceNumber & ~UInt64(0xFFFF)

        if sequenceNumber < highestLowBits, highestLowBits - sequenceNumber > 0x8000 {
            cycle += 1 << 16
        } else if sequenceNumber > highestLowBits,
                  sequenceNumber - highestLowBits > 0x8000,
                  cycle >= 1 << 16 {
            cycle -= 1 << 16
        }

        let extended = cycle | UInt64(sequenceNumber)
        if extended > highestExtendedSequenceNumber {
            self.highestExtendedSequenceNumber = extended
        }

        return extended
    }
}

package struct SRTPReplayWindow: Equatable, Sendable {
    package let size: Int
    private var highestIndex: UInt64?
    private var seenMask: UInt64

    package init(size: Int = 64) {
        self.size = min(max(size, 1), 64)
        self.highestIndex = nil
        self.seenMask = 0
    }

    package var highestAcceptedIndex: UInt64? {
        highestIndex
    }

    package func canAccept(_ packetIndex: UInt64) -> Bool {
        guard let highestIndex else {
            return true
        }

        if packetIndex > highestIndex {
            return true
        }

        let delta = highestIndex - packetIndex
        guard delta < UInt64(size) else {
            return false
        }

        return (seenMask & (1 << delta)) == 0
    }

    package mutating func accept(_ packetIndex: UInt64) -> Bool {
        guard let highestIndex else {
            self.highestIndex = packetIndex
            seenMask = 1
            return true
        }

        if packetIndex > highestIndex {
            let shift = packetIndex - highestIndex
            if shift >= UInt64(size) {
                seenMask = 1
            } else {
                seenMask = (seenMask << shift) | 1
            }
            self.highestIndex = packetIndex
            return true
        }

        let delta = highestIndex - packetIndex
        guard delta < UInt64(size) else {
            return false
        }

        let mask = UInt64(1) << delta
        guard (seenMask & mask) == 0 else {
            return false
        }

        seenMask |= mask
        return true
    }
}

package struct SRTPReplayProtector: Equatable, Sendable {
    private var statesBySSRC: [UInt32: SSRCReplayState]
    private let windowSize: Int

    package init(windowSize: Int = 64) {
        self.windowSize = windowSize
        self.statesBySSRC = [:]
    }

    package mutating func accept(_ packet: RTPPacket) -> Bool {
        accept(ssrc: packet.ssrc, sequenceNumber: packet.sequenceNumber)
    }

    package mutating func accept(ssrc: UInt32, sequenceNumber: UInt16) -> Bool {
        var state = statesBySSRC[ssrc] ?? SSRCReplayState(windowSize: windowSize)
        let packetIndex = state.sequenceNumberExtender.extend(sequenceNumber)
        let accepted = state.replayWindow.accept(packetIndex)
        statesBySSRC[ssrc] = state
        return accepted
    }

    package func highestAcceptedIndex(for ssrc: UInt32) -> UInt64? {
        statesBySSRC[ssrc]?.replayWindow.highestAcceptedIndex
    }
}

private struct SSRCReplayState: Equatable, Sendable {
    var sequenceNumberExtender: RTPSequenceNumberExtender
    var replayWindow: SRTPReplayWindow

    init(windowSize: Int) {
        self.sequenceNumberExtender = RTPSequenceNumberExtender()
        self.replayWindow = SRTPReplayWindow(size: windowSize)
    }
}

package enum SRTPError: Error, Equatable, Sendable {
    case packetTooShort
    case invalidAuthenticationTagLength(Int)
    case emptyAuthenticationKey
    case authenticationFailed
    case replayedPacket
    case invalidSessionEncryptionKeyLength(Int)
    case invalidSessionSaltLength(Int)
    case payloadTooLarge(Int)
    case aesOperationFailed(Int32)
}

package struct SRTPAESCounterModeCipher: Equatable, Sendable {
    package static let sessionEncryptionKeyLength = kCCKeySizeAES128
    package static let sessionSaltLength = 14
    package static let maximumKeystreamBlocks = 1 << 16

    package var sessionEncryptionKey: Data
    package var sessionSalt: Data

    package init(sessionEncryptionKey: Data, sessionSalt: Data) throws {
        guard sessionEncryptionKey.count == Self.sessionEncryptionKeyLength else {
            throw SRTPError.invalidSessionEncryptionKeyLength(sessionEncryptionKey.count)
        }
        guard sessionSalt.count == Self.sessionSaltLength else {
            throw SRTPError.invalidSessionSaltLength(sessionSalt.count)
        }

        self.sessionEncryptionKey = sessionEncryptionKey
        self.sessionSalt = sessionSalt
    }

    package func encrypt(_ packet: RTPPacket, rolloverCounter: UInt32) throws -> RTPPacket {
        try transform(packet, rolloverCounter: rolloverCounter)
    }

    package func decrypt(_ packet: RTPPacket, rolloverCounter: UInt32) throws -> RTPPacket {
        try transform(packet, rolloverCounter: rolloverCounter)
    }

    package func encryptPayload(
        _ payload: Data,
        ssrc: UInt32,
        rolloverCounter: UInt32,
        sequenceNumber: UInt16
    ) throws -> Data {
        try transformPayload(
            payload,
            ssrc: ssrc,
            rolloverCounter: rolloverCounter,
            sequenceNumber: sequenceNumber
        )
    }

    package func decryptPayload(
        _ payload: Data,
        ssrc: UInt32,
        rolloverCounter: UInt32,
        sequenceNumber: UInt16
    ) throws -> Data {
        try transformPayload(
            payload,
            ssrc: ssrc,
            rolloverCounter: rolloverCounter,
            sequenceNumber: sequenceNumber
        )
    }

    package func initializationVector(
        ssrc: UInt32,
        rolloverCounter: UInt32,
        sequenceNumber: UInt16
    ) -> Data {
        var iv = Array(sessionSalt)
        iv.append(0)
        iv.append(0)

        iv[4] ^= UInt8((ssrc >> 24) & 0xFF)
        iv[5] ^= UInt8((ssrc >> 16) & 0xFF)
        iv[6] ^= UInt8((ssrc >> 8) & 0xFF)
        iv[7] ^= UInt8(ssrc & 0xFF)

        iv[8] ^= UInt8((rolloverCounter >> 24) & 0xFF)
        iv[9] ^= UInt8((rolloverCounter >> 16) & 0xFF)
        iv[10] ^= UInt8((rolloverCounter >> 8) & 0xFF)
        iv[11] ^= UInt8(rolloverCounter & 0xFF)
        iv[12] ^= UInt8((sequenceNumber >> 8) & 0xFF)
        iv[13] ^= UInt8(sequenceNumber & 0xFF)

        return Data(iv)
    }

    private func transform(_ packet: RTPPacket, rolloverCounter: UInt32) throws -> RTPPacket {
        var transformed = packet
        transformed.payload = try transformPayload(
            packet.payload,
            ssrc: packet.ssrc,
            rolloverCounter: rolloverCounter,
            sequenceNumber: packet.sequenceNumber
        )
        return transformed
    }

    private func transformPayload(
        _ payload: Data,
        ssrc: UInt32,
        rolloverCounter: UInt32,
        sequenceNumber: UInt16
    ) throws -> Data {
        guard !payload.isEmpty else {
            return payload
        }

        let blockCount = (payload.count + kCCBlockSizeAES128 - 1) / kCCBlockSizeAES128
        guard blockCount <= Self.maximumKeystreamBlocks else {
            throw SRTPError.payloadTooLarge(payload.count)
        }

        let baseIV = initializationVector(
            ssrc: ssrc,
            rolloverCounter: rolloverCounter,
            sequenceNumber: sequenceNumber
        )
        let payloadBytes = Array(payload)
        var output = [UInt8]()
        output.reserveCapacity(payload.count)

        for blockIndex in 0..<blockCount {
            var counterBlock = Array(baseIV)
            counterBlock[14] = UInt8((blockIndex >> 8) & 0xFF)
            counterBlock[15] = UInt8(blockIndex & 0xFF)

            let keystreamBlock = try encryptCounterBlock(counterBlock)
            let offset = blockIndex * kCCBlockSizeAES128
            let count = min(kCCBlockSizeAES128, payload.count - offset)

            for byteIndex in 0..<count {
                output.append(payloadBytes[offset + byteIndex] ^ keystreamBlock[byteIndex])
            }
        }

        return Data(output)
    }

    private func encryptCounterBlock(_ counterBlock: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var outputLength = 0
        let status = sessionEncryptionKey.withUnsafeBytes { keyBytes in
            counterBlock.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        sessionEncryptionKey.count,
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
            throw SRTPError.aesOperationFailed(status)
        }

        return output
    }
}

package struct SRTPProtectedPacket: Equatable, Sendable {
    package static let defaultAuthenticationTagLength = 10

    package var rtpPacket: RTPPacket
    package var rolloverCounter: UInt32
    package var authenticationTag: Data

    package init(
        rtpPacket: RTPPacket,
        rolloverCounter: UInt32,
        authenticationTag: Data = Data()
    ) {
        self.rtpPacket = rtpPacket
        self.rolloverCounter = rolloverCounter
        self.authenticationTag = authenticationTag
    }

    package init(
        decoding data: Data,
        rolloverCounter: UInt32,
        authenticationTagLength: Int = Self.defaultAuthenticationTagLength
    ) throws {
        guard authenticationTagLength >= 0 else {
            throw SRTPError.invalidAuthenticationTagLength(authenticationTagLength)
        }
        guard data.count >= 12 + authenticationTagLength else {
            throw SRTPError.packetTooShort
        }

        let rtpByteCount = data.count - authenticationTagLength
        self.rtpPacket = try RTPPacket(decoding: Data(data.prefix(rtpByteCount)))
        self.rolloverCounter = rolloverCounter
        self.authenticationTag = Data(data.suffix(authenticationTagLength))
    }

    package func encoded() -> Data {
        var data = rtpPacket.encoded()
        data.append(authenticationTag)
        return data
    }

    package func authenticationInput() -> Data {
        var data = rtpPacket.encoded()
        data.appendNetworkUInt32(rolloverCounter)
        return data
    }
}

package struct SRTPAuthenticator: Equatable, Sendable {
    package var authenticationKey: Data
    package var tagLength: Int

    package init(
        authenticationKey: Data,
        tagLength: Int = SRTPProtectedPacket.defaultAuthenticationTagLength
    ) throws {
        guard !authenticationKey.isEmpty else {
            throw SRTPError.emptyAuthenticationKey
        }
        guard tagLength > 0, tagLength <= Insecure.SHA1.byteCount else {
            throw SRTPError.invalidAuthenticationTagLength(tagLength)
        }

        self.authenticationKey = authenticationKey
        self.tagLength = tagLength
    }

    package func authenticate(_ rtpPacket: RTPPacket, rolloverCounter: UInt32) throws -> SRTPProtectedPacket {
        let packet = SRTPProtectedPacket(
            rtpPacket: rtpPacket,
            rolloverCounter: rolloverCounter
        )
        return try authenticate(packet)
    }

    package func authenticate(_ packet: SRTPProtectedPacket) throws -> SRTPProtectedPacket {
        var authenticated = packet
        authenticated.authenticationTag = authenticationTag(for: packet)
        return authenticated
    }

    package func validate(_ packet: SRTPProtectedPacket) throws {
        let expected = authenticationTag(for: packet)
        guard constantTimeEquals(packet.authenticationTag, expected) else {
            throw SRTPError.authenticationFailed
        }
    }

    package func authenticationTag(for packet: SRTPProtectedPacket) -> Data {
        let key = SymmetricKey(data: authenticationKey)
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: packet.authenticationInput(), using: key)
        return Data(code).prefixData(tagLength)
    }

    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

package struct SRTPPacketProtector: Equatable, Sendable {
    package var cipher: SRTPAESCounterModeCipher
    package var authenticator: SRTPAuthenticator

    package init(cipher: SRTPAESCounterModeCipher, authenticator: SRTPAuthenticator) {
        self.cipher = cipher
        self.authenticator = authenticator
    }

    package func protect(_ packet: RTPPacket, rolloverCounter: UInt32) throws -> SRTPProtectedPacket {
        let encrypted = try cipher.encrypt(packet, rolloverCounter: rolloverCounter)
        return try authenticator.authenticate(encrypted, rolloverCounter: rolloverCounter)
    }

    package func unprotect(_ packet: SRTPProtectedPacket) throws -> RTPPacket {
        try authenticator.validate(packet)
        return try cipher.decrypt(packet.rtpPacket, rolloverCounter: packet.rolloverCounter)
    }

    package func unprotect(
        encoded data: Data,
        rolloverCounter: UInt32,
        authenticationTagLength: Int = SRTPProtectedPacket.defaultAuthenticationTagLength
    ) throws -> RTPPacket {
        let packet = try SRTPProtectedPacket(
            decoding: data,
            rolloverCounter: rolloverCounter,
            authenticationTagLength: authenticationTagLength
        )
        return try unprotect(packet)
    }
}

package struct SRTPPacketUnprotector: Equatable, Sendable {
    package var protector: SRTPPacketProtector
    package var replayProtector: SRTPReplayProtector

    package init(protector: SRTPPacketProtector, replayProtector: SRTPReplayProtector = SRTPReplayProtector()) {
        self.protector = protector
        self.replayProtector = replayProtector
    }

    package mutating func unprotect(_ packet: SRTPProtectedPacket) throws -> RTPPacket {
        let decrypted = try protector.unprotect(packet)
        guard replayProtector.accept(packet.rtpPacket) else {
            throw SRTPError.replayedPacket
        }
        return decrypted
    }

    package mutating func unprotect(
        encoded data: Data,
        rolloverCounter: UInt32,
        authenticationTagLength: Int = SRTPProtectedPacket.defaultAuthenticationTagLength
    ) throws -> RTPPacket {
        let packet = try SRTPProtectedPacket(
            decoding: data,
            rolloverCounter: rolloverCounter,
            authenticationTagLength: authenticationTagLength
        )
        return try unprotect(packet)
    }
}

package enum SRTCPError: Error, Equatable, Sendable {
    case packetTooShort
    case invalidLength
    case invalidAuthenticationTagLength(Int)
    case indexOutOfRange(UInt32)
    case emptyAuthenticationKey
    case authenticationFailed
    case replayedPacket
}

package struct SRTCPIndex: Equatable, Sendable {
    package static let maxValue: UInt32 = 0x7FFF_FFFF

    package var value: UInt32
    package var isEncrypted: Bool

    package init(value: UInt32, isEncrypted: Bool = false) throws {
        guard value <= Self.maxValue else {
            throw SRTCPError.indexOutOfRange(value)
        }

        self.value = value
        self.isEncrypted = isEncrypted
    }

    package init(rawValue: UInt32) {
        self.value = rawValue & Self.maxValue
        self.isEncrypted = (rawValue & 0x8000_0000) != 0
    }

    package var rawValue: UInt32 {
        (isEncrypted ? 0x8000_0000 : 0) | value
    }
}

package struct SRTCPPacket: Equatable, Sendable {
    package static let defaultAuthenticationTagLength = 10

    package var rtcpPacket: RTCPPacket
    package var index: SRTCPIndex
    package var authenticationTag: Data

    package init(rtcpPacket: RTCPPacket, index: SRTCPIndex, authenticationTag: Data = Data()) {
        self.rtcpPacket = rtcpPacket
        self.index = index
        self.authenticationTag = authenticationTag
    }

    package init(decoding data: Data, authenticationTagLength: Int = Self.defaultAuthenticationTagLength) throws {
        guard authenticationTagLength >= 0 else {
            throw SRTCPError.invalidAuthenticationTagLength(authenticationTagLength)
        }
        guard data.count >= 8 + authenticationTagLength else {
            throw SRTCPError.packetTooShort
        }

        let rtcpByteCount = try Self.rtcpByteCount(in: data)
        guard data.count == rtcpByteCount + 4 + authenticationTagLength else {
            throw SRTCPError.invalidLength
        }

        let rtcpData = Data(data.prefix(rtcpByteCount))
        self.rtcpPacket = try RTCPPacket(decoding: rtcpData)
        self.index = SRTCPIndex(rawValue: try data.networkUInt32(at: rtcpByteCount))
        let tagStart = data.index(data.startIndex, offsetBy: rtcpByteCount + 4)
        self.authenticationTag = Data(data[tagStart..<data.endIndex])
    }

    package var senderSSRC: UInt32 {
        rtcpPacket.senderSSRC
    }

    package func encoded() throws -> Data {
        var data = try authenticationInput()
        data.append(authenticationTag)
        return data
    }

    package func authenticationInput() throws -> Data {
        var data = try rtcpPacket.encoded()
        data.appendNetworkUInt32(index.rawValue)
        return data
    }

    private static func rtcpByteCount(in data: Data) throws -> Int {
        guard data.count >= 4 else {
            throw SRTCPError.packetTooShort
        }

        let length = try data.networkUInt16(at: 2)
        let byteCount = Int(length + 1) * 4
        guard byteCount >= 4 else {
            throw SRTCPError.invalidLength
        }

        return byteCount
    }
}

package struct SRTCPReplayProtector: Equatable, Sendable {
    private var windowsBySSRC: [UInt32: SRTPReplayWindow]
    private let windowSize: Int

    package init(windowSize: Int = 64) {
        self.windowSize = windowSize
        self.windowsBySSRC = [:]
    }

    package mutating func accept(_ packet: SRTCPPacket) -> Bool {
        accept(senderSSRC: packet.senderSSRC, index: packet.index.value)
    }

    package mutating func accept(senderSSRC: UInt32, index: UInt32) -> Bool {
        var window = windowsBySSRC[senderSSRC] ?? SRTPReplayWindow(size: windowSize)
        let accepted = window.accept(UInt64(index))
        windowsBySSRC[senderSSRC] = window
        return accepted
    }

    package func highestAcceptedIndex(for senderSSRC: UInt32) -> UInt64? {
        windowsBySSRC[senderSSRC]?.highestAcceptedIndex
    }
}

package struct SRTCPAESCounterModeCipher: Equatable, Sendable {
    package var cipher: SRTPAESCounterModeCipher

    package init(sessionEncryptionKey: Data, sessionSalt: Data) throws {
        self.cipher = try SRTPAESCounterModeCipher(
            sessionEncryptionKey: sessionEncryptionKey,
            sessionSalt: sessionSalt
        )
    }

    package init(cipher: SRTPAESCounterModeCipher) {
        self.cipher = cipher
    }

    package func encrypt(_ packet: SRTCPPacket) throws -> SRTCPPacket {
        try transform(packet, isEncrypted: true)
    }

    package func decrypt(_ packet: SRTCPPacket) throws -> SRTCPPacket {
        guard packet.index.isEncrypted else {
            return packet
        }

        return try transform(packet, isEncrypted: false)
    }

    private func transform(_ packet: SRTCPPacket, isEncrypted: Bool) throws -> SRTCPPacket {
        let rtcpData = try packet.rtcpPacket.encoded()
        guard rtcpData.count >= 8 else {
            throw SRTCPError.invalidLength
        }

        let header = Data(rtcpData.prefix(8))
        let payload = Data(rtcpData.dropFirst(8))
        let transformedPayload = try cipher.encryptPayload(
            payload,
            ssrc: packet.senderSSRC,
            rolloverCounter: UInt32(packet.index.value >> 16),
            sequenceNumber: UInt16(packet.index.value & 0xFFFF)
        )

        var transformedRTCPData = header
        transformedRTCPData.append(transformedPayload)

        return SRTCPPacket(
            rtcpPacket: try RTCPPacket(decoding: transformedRTCPData),
            index: try SRTCPIndex(value: packet.index.value, isEncrypted: isEncrypted),
            authenticationTag: packet.authenticationTag
        )
    }
}

package struct SRTCPAuthenticator: Equatable, Sendable {
    package var authenticationKey: Data
    package var tagLength: Int

    package init(
        authenticationKey: Data,
        tagLength: Int = SRTCPPacket.defaultAuthenticationTagLength
    ) throws {
        guard !authenticationKey.isEmpty else {
            throw SRTCPError.emptyAuthenticationKey
        }
        guard tagLength > 0, tagLength <= Insecure.SHA1.byteCount else {
            throw SRTCPError.invalidAuthenticationTagLength(tagLength)
        }

        self.authenticationKey = authenticationKey
        self.tagLength = tagLength
    }

    package func authenticate(_ packet: SRTCPPacket) throws -> SRTCPPacket {
        var authenticated = packet
        authenticated.authenticationTag = try authenticationTag(for: packet)
        return authenticated
    }

    package func validate(_ packet: SRTCPPacket) throws {
        let expected = try authenticationTag(for: packet)
        guard constantTimeEquals(packet.authenticationTag, expected) else {
            throw SRTCPError.authenticationFailed
        }
    }

    package func authenticationTag(for packet: SRTCPPacket) throws -> Data {
        let key = SymmetricKey(data: authenticationKey)
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: try packet.authenticationInput(), using: key)
        return Data(code).prefixData(tagLength)
    }

    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

package struct SRTCPPacketProtector: Equatable, Sendable {
    package var cipher: SRTCPAESCounterModeCipher
    package var authenticator: SRTCPAuthenticator

    package init(cipher: SRTCPAESCounterModeCipher, authenticator: SRTCPAuthenticator) {
        self.cipher = cipher
        self.authenticator = authenticator
    }

    package func protect(_ packet: SRTCPPacket) throws -> SRTCPPacket {
        let encrypted = try cipher.encrypt(packet)
        return try authenticator.authenticate(encrypted)
    }

    package func unprotect(_ packet: SRTCPPacket) throws -> SRTCPPacket {
        try authenticator.validate(packet)
        var decrypted = try cipher.decrypt(packet)
        decrypted.authenticationTag = Data()
        return decrypted
    }

    package func unprotect(
        encoded data: Data,
        authenticationTagLength: Int = SRTCPPacket.defaultAuthenticationTagLength
    ) throws -> SRTCPPacket {
        let packet = try SRTCPPacket(decoding: data, authenticationTagLength: authenticationTagLength)
        return try unprotect(packet)
    }
}

package struct SRTCPPacketUnprotector: Equatable, Sendable {
    package var protector: SRTCPPacketProtector
    package var replayProtector: SRTCPReplayProtector

    package init(protector: SRTCPPacketProtector, replayProtector: SRTCPReplayProtector = SRTCPReplayProtector()) {
        self.protector = protector
        self.replayProtector = replayProtector
    }

    package mutating func unprotect(_ packet: SRTCPPacket) throws -> SRTCPPacket {
        let decrypted = try protector.unprotect(packet)
        guard replayProtector.accept(packet) else {
            throw SRTCPError.replayedPacket
        }
        return decrypted
    }

    package mutating func unprotect(
        encoded data: Data,
        authenticationTagLength: Int = SRTCPPacket.defaultAuthenticationTagLength
    ) throws -> SRTCPPacket {
        let packet = try SRTCPPacket(decoding: data, authenticationTagLength: authenticationTagLength)
        return try unprotect(packet)
    }
}

private extension Data {
    mutating func appendNetworkUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func networkUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw SRTCPError.invalidLength
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return UInt16(self[first]) << 8 | UInt16(self[second])
    }

    func networkUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw SRTCPError.invalidLength
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        let third = index(after: second)
        let fourth = index(after: third)

        return UInt32(self[first]) << 24 |
            UInt32(self[second]) << 16 |
            UInt32(self[third]) << 8 |
            UInt32(self[fourth])
    }

    func prefixData(_ count: Int) -> Data {
        Data(prefix(count))
    }
}
