import CryptoKit
import Foundation

package enum STUNError: Error, Equatable, Sendable {
    case packetTooShort
    case invalidMessageLength
    case invalidMagicCookie(UInt32)
    case invalidTransactionIDLength(Int)
    case invalidUTF8Attribute(UInt16)
    case invalidAddressAttribute
    case invalidErrorCodeAttribute
    case missingAttribute(UInt16)
    case invalidAttributeLength(UInt16, Int)
    case unsupportedAddressFamily(UInt8)
    case invalidChannelNumber(UInt16)
}

package struct STUNMessageType: RawRepresentable, Equatable, Sendable {
    package var rawValue: UInt16

    package init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    package static let bindingRequest = STUNMessageType(rawValue: 0x0001)
    package static let allocateRequest = STUNMessageType(rawValue: 0x0003)
    package static let refreshRequest = STUNMessageType(rawValue: 0x0004)
    package static let createPermissionRequest = STUNMessageType(rawValue: 0x0008)
    package static let channelBindRequest = STUNMessageType(rawValue: 0x0009)
    package static let bindingSuccessResponse = STUNMessageType(rawValue: 0x0101)
    package static let allocateSuccessResponse = STUNMessageType(rawValue: 0x0103)
    package static let refreshSuccessResponse = STUNMessageType(rawValue: 0x0104)
    package static let createPermissionSuccessResponse = STUNMessageType(rawValue: 0x0108)
    package static let channelBindSuccessResponse = STUNMessageType(rawValue: 0x0109)
    package static let bindingErrorResponse = STUNMessageType(rawValue: 0x0111)
    package static let allocateErrorResponse = STUNMessageType(rawValue: 0x0113)
    package static let refreshErrorResponse = STUNMessageType(rawValue: 0x0114)
    package static let createPermissionErrorResponse = STUNMessageType(rawValue: 0x0118)
    package static let channelBindErrorResponse = STUNMessageType(rawValue: 0x0119)
}

package struct STUNTransactionID: Equatable, Sendable {
    package static let byteCount = 12

    package var bytes: [UInt8]

    package init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw STUNError.invalidTransactionIDLength(bytes.count)
        }

        self.bytes = bytes
    }

    package static func random() -> STUNTransactionID {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return try! STUNTransactionID(bytes: bytes)
    }
}

package enum STUNAttributeType: UInt16, Equatable, Sendable {
    case mappedAddress = 0x0001
    case username = 0x0006
    case messageIntegrity = 0x0008
    case errorCode = 0x0009
    case channelNumber = 0x000C
    case lifetime = 0x000D
    case xorPeerAddress = 0x0012
    case realm = 0x0014
    case nonce = 0x0015
    case xorRelayedAddress = 0x0016
    case requestedTransport = 0x0019
    case xorMappedAddress = 0x0020
    case priority = 0x0024
    case useCandidate = 0x0025
    case fingerprint = 0x8028
    case iceControlled = 0x8029
    case iceControlling = 0x802A
}

package enum TURNRequestedTransportProtocol: UInt8, Equatable, Sendable {
    case tcp = 6
    case udp = 17
}

package struct STUNMappedAddress: Equatable, Sendable {
    package var address: String
    package var port: UInt16

    package init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

package struct STUNErrorCode: Equatable, Sendable {
    package var code: Int
    package var reason: String

    package init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

package struct STUNAttribute: Equatable, Sendable {
    package var type: UInt16
    package var value: Data

    package init(type: UInt16, value: Data = Data()) {
        self.type = type
        self.value = value
    }

    package init(type: STUNAttributeType, value: Data = Data()) {
        self.init(type: type.rawValue, value: value)
    }

    package static func username(_ value: String) -> STUNAttribute {
        STUNAttribute(type: .username, value: Data(value.utf8))
    }

    package static func realm(_ value: String) -> STUNAttribute {
        STUNAttribute(type: .realm, value: Data(value.utf8))
    }

    package static func nonce(_ value: String) -> STUNAttribute {
        STUNAttribute(type: .nonce, value: Data(value.utf8))
    }

    package static func lifetime(seconds: UInt32) -> STUNAttribute {
        var data = Data()
        data.appendNetworkUInt32(seconds)
        return STUNAttribute(type: .lifetime, value: data)
    }

    package static func channelNumber(_ value: UInt16) -> STUNAttribute {
        var data = Data()
        data.appendNetworkUInt16(value)
        data.appendNetworkUInt16(0)
        return STUNAttribute(type: .channelNumber, value: data)
    }

    package static func requestedTransport(_ transport: TURNRequestedTransportProtocol) -> STUNAttribute {
        STUNAttribute(type: .requestedTransport, value: Data([transport.rawValue, 0, 0, 0]))
    }

    package static func priority(_ value: UInt32) -> STUNAttribute {
        var data = Data()
        data.appendNetworkUInt32(value)
        return STUNAttribute(type: .priority, value: data)
    }

    package static let useCandidate = STUNAttribute(type: .useCandidate)

    package static func messageIntegrity(_ value: Data) -> STUNAttribute {
        STUNAttribute(type: .messageIntegrity, value: value)
    }

    package static func errorCode(_ code: Int, reason: String) -> STUNAttribute {
        var data = Data([0, 0, UInt8((code / 100) & 0x07), UInt8(code % 100)])
        data.append(contentsOf: reason.utf8)
        return STUNAttribute(type: .errorCode, value: data)
    }

    package static func fingerprint(_ value: UInt32) -> STUNAttribute {
        var data = Data()
        data.appendNetworkUInt32(value)
        return STUNAttribute(type: .fingerprint, value: data)
    }

    package static func xorMappedAddressIPv4(
        address: String,
        port: UInt16,
        transactionID: STUNTransactionID
    ) throws -> STUNAttribute {
        try xorAddressIPv4Attribute(
            type: .xorMappedAddress,
            address: address,
            port: port,
            transactionID: transactionID
        )
    }

    package static func xorRelayedAddressIPv4(
        address: String,
        port: UInt16,
        transactionID: STUNTransactionID
    ) throws -> STUNAttribute {
        try xorAddressIPv4Attribute(
            type: .xorRelayedAddress,
            address: address,
            port: port,
            transactionID: transactionID
        )
    }

    package static func xorPeerAddressIPv4(
        address: String,
        port: UInt16,
        transactionID: STUNTransactionID
    ) throws -> STUNAttribute {
        try xorAddressIPv4Attribute(
            type: .xorPeerAddress,
            address: address,
            port: port,
            transactionID: transactionID
        )
    }

    package static func iceControlled(tieBreaker: UInt64) -> STUNAttribute {
        var data = Data()
        data.appendNetworkUInt64(tieBreaker)
        return STUNAttribute(type: .iceControlled, value: data)
    }

    package static func iceControlling(tieBreaker: UInt64) -> STUNAttribute {
        var data = Data()
        data.appendNetworkUInt64(tieBreaker)
        return STUNAttribute(type: .iceControlling, value: data)
    }

    package var stringValue: String? {
        get throws {
            guard let string = String(data: value, encoding: .utf8) else {
                throw STUNError.invalidUTF8Attribute(type)
            }

            return string
        }
    }

    package var uint32Value: UInt32? {
        guard value.count == 4 else { return nil }
        return try? value.networkUInt32(at: 0)
    }

    package var channelNumberValue: UInt16? {
        guard type == STUNAttributeType.channelNumber.rawValue,
              value.count == 4,
              (try? value.networkUInt16(at: 2)) == 0
        else {
            return nil
        }

        return try? value.networkUInt16(at: 0)
    }

    package var uint64Value: UInt64? {
        guard value.count == 8 else { return nil }
        return try? value.networkUInt64(at: 0)
    }

    package var errorCodeValue: STUNErrorCode? {
        get throws {
            guard type == STUNAttributeType.errorCode.rawValue else {
                return nil
            }

            guard value.count >= 4 else {
                throw STUNError.invalidErrorCodeAttribute
            }

            guard value[value.startIndex] == 0,
                  value[value.index(after: value.startIndex)] == 0
            else {
                throw STUNError.invalidErrorCodeAttribute
            }

            let classByte = value[value.index(value.startIndex, offsetBy: 2)]
            guard classByte & 0xF8 == 0 else {
                throw STUNError.invalidErrorCodeAttribute
            }

            let classValue = Int(value[value.index(value.startIndex, offsetBy: 2)] & 0x07)
            let numberValue = Int(value[value.index(value.startIndex, offsetBy: 3)])
            guard (3...6).contains(classValue), numberValue < 100 else {
                throw STUNError.invalidErrorCodeAttribute
            }

            let reasonData = Data(value.dropFirst(4))
            guard let reason = String(data: reasonData, encoding: .utf8) else {
                throw STUNError.invalidUTF8Attribute(type)
            }

            return STUNErrorCode(code: (classValue * 100) + numberValue, reason: reason)
        }
    }

    package var requestedTransportProtocol: TURNRequestedTransportProtocol? {
        guard type == STUNAttributeType.requestedTransport.rawValue,
              value.count == 4
        else {
            return nil
        }

        return TURNRequestedTransportProtocol(rawValue: value[value.startIndex])
    }

    package var xorMappedAddressValue: STUNMappedAddress? {
        get throws {
            try xorAddressValue(expectedType: .xorMappedAddress)
        }
    }

    package var xorRelayedAddressValue: STUNMappedAddress? {
        get throws {
            try xorAddressValue(expectedType: .xorRelayedAddress)
        }
    }

    package var xorPeerAddressValue: STUNMappedAddress? {
        get throws {
            try xorAddressValue(expectedType: .xorPeerAddress)
        }
    }

    fileprivate func encode(into data: inout Data) {
        data.appendNetworkUInt16(type)
        data.appendNetworkUInt16(UInt16(value.count))
        data.append(value)
        data.appendSTUNPadding(forValueLength: value.count)
    }

    private static func ipv4Octets(from address: String) throws -> [UInt8] {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else {
            throw STUNError.invalidAddressAttribute
        }

        return try parts.map { part in
            guard let value = UInt8(part) else {
                throw STUNError.invalidAddressAttribute
            }

            return value
        }
    }

    private static func xorAddressIPv4Attribute(
        type: STUNAttributeType,
        address: String,
        port: UInt16,
        transactionID: STUNTransactionID
    ) throws -> STUNAttribute {
        _ = transactionID
        let octets = try ipv4Octets(from: address)
        let addressValue = UInt32(octets[0]) << 24 |
            UInt32(octets[1]) << 16 |
            UInt32(octets[2]) << 8 |
            UInt32(octets[3])
        let xoredPort = port ^ UInt16(STUNMessage.magicCookie >> 16)
        let xoredAddress = addressValue ^ STUNMessage.magicCookie

        var data = Data()
        data.append(0)
        data.append(0x01)
        data.appendNetworkUInt16(xoredPort)
        data.appendNetworkUInt32(xoredAddress)
        return STUNAttribute(type: type, value: data)
    }

    private func xorAddressValue(expectedType: STUNAttributeType) throws -> STUNMappedAddress? {
        guard type == expectedType.rawValue else {
            return nil
        }

        guard value.count >= 8 else {
            throw STUNError.invalidAddressAttribute
        }

        let family = value[value.index(value.startIndex, offsetBy: 1)]
        let port = try value.networkUInt16(at: 2) ^ UInt16(STUNMessage.magicCookie >> 16)

        switch family {
        case 0x01:
            let address = try value.networkUInt32(at: 4) ^ STUNMessage.magicCookie
            return STUNMappedAddress(
                address: [
                    String((address >> 24) & 0xFF),
                    String((address >> 16) & 0xFF),
                    String((address >> 8) & 0xFF),
                    String(address & 0xFF),
                ].joined(separator: "."),
                port: port
            )
        default:
            throw STUNError.unsupportedAddressFamily(family)
        }
    }
}

package enum TURNAllocateRequestFactory {
    package static func makeAllocateRequest(
        relayedTransport: TURNRequestedTransportProtocol = .udp,
        username: String? = nil,
        realm: String? = nil,
        nonce: String? = nil,
        lifetimeSeconds: UInt32? = nil,
        transactionID: STUNTransactionID = .random()
    ) -> STUNMessage {
        var attributes: [STUNAttribute] = [
            .requestedTransport(relayedTransport),
        ]

        if let lifetimeSeconds {
            attributes.append(.lifetime(seconds: lifetimeSeconds))
        }
        if let username {
            attributes.append(.username(username))
        }
        if let realm {
            attributes.append(.realm(realm))
        }
        if let nonce {
            attributes.append(.nonce(nonce))
        }

        return STUNMessage(
            type: .allocateRequest,
            transactionID: transactionID,
            attributes: attributes
        )
    }
}

package enum TURNRefreshRequestFactory {
    package static func makeRefreshRequest(
        username: String,
        realm: String,
        nonce: String,
        lifetimeSeconds: UInt32,
        transactionID: STUNTransactionID = .random()
    ) -> STUNMessage {
        STUNMessage(
            type: .refreshRequest,
            transactionID: transactionID,
            attributes: [
                .lifetime(seconds: lifetimeSeconds),
                .username(username),
                .realm(realm),
                .nonce(nonce),
            ]
        )
    }
}

package enum TURNCreatePermissionRequestFactory {
    package static func makeCreatePermissionRequest(
        peerAddresses: [STUNMappedAddress],
        username: String,
        realm: String,
        nonce: String,
        transactionID: STUNTransactionID = .random()
    ) throws -> STUNMessage {
        guard !peerAddresses.isEmpty else {
            throw STUNError.missingAttribute(STUNAttributeType.xorPeerAddress.rawValue)
        }

        var attributes = try peerAddresses.map {
            try STUNAttribute.xorPeerAddressIPv4(
                address: $0.address,
                port: $0.port,
                transactionID: transactionID
            )
        }
        attributes.append(contentsOf: [
            .username(username),
            .realm(realm),
            .nonce(nonce),
        ])

        return STUNMessage(
            type: .createPermissionRequest,
            transactionID: transactionID,
            attributes: attributes
        )
    }
}

package enum TURNChannelBindRequestFactory {
    package static func makeChannelBindRequest(
        channelNumber: UInt16,
        peerAddress: STUNMappedAddress,
        username: String,
        realm: String,
        nonce: String,
        transactionID: STUNTransactionID = .random()
    ) throws -> STUNMessage {
        guard (0x4000 ... 0x7FFF).contains(channelNumber) else {
            throw STUNError.invalidChannelNumber(channelNumber)
        }

        return STUNMessage(
            type: .channelBindRequest,
            transactionID: transactionID,
            attributes: [
                .channelNumber(channelNumber),
                try .xorPeerAddressIPv4(
                    address: peerAddress.address,
                    port: peerAddress.port,
                    transactionID: transactionID
                ),
                .username(username),
                .realm(realm),
                .nonce(nonce),
            ]
        )
    }
}

package struct STUNMessage: Equatable, Sendable {
    package static let magicCookie: UInt32 = 0x2112A442
    package static let fingerprintXORValue: UInt32 = 0x5354554E

    package var type: STUNMessageType
    package var transactionID: STUNTransactionID
    package var attributes: [STUNAttribute]
    private var originalData: Data?

    package static func == (lhs: STUNMessage, rhs: STUNMessage) -> Bool {
        lhs.type == rhs.type &&
            lhs.transactionID == rhs.transactionID &&
            lhs.attributes == rhs.attributes
    }

    package init(
        type: STUNMessageType,
        transactionID: STUNTransactionID = .random(),
        attributes: [STUNAttribute] = []
    ) {
        self.type = type
        self.transactionID = transactionID
        self.attributes = attributes
        self.originalData = nil
    }

    package init(decoding data: Data) throws {
        guard data.count >= 20 else {
            throw STUNError.packetTooShort
        }

        let messageType = try data.networkUInt16(at: 0)
        let messageLength = Int(try data.networkUInt16(at: 2))
        guard messageLength % 4 == 0, data.count == 20 + messageLength else {
            throw STUNError.invalidMessageLength
        }

        let magicCookie = try data.networkUInt32(at: 4)
        guard magicCookie == Self.magicCookie else {
            throw STUNError.invalidMagicCookie(magicCookie)
        }

        let transactionBytes = Array(data[8..<20])
        var attributes: [STUNAttribute] = []
        var offset = 20

        while offset < data.count {
            guard offset + 4 <= data.count else {
                throw STUNError.invalidMessageLength
            }

            let type = try data.networkUInt16(at: offset)
            let valueLength = Int(try data.networkUInt16(at: offset + 2))
            let paddedLength = valueLength.stunPaddedLength
            let valueStart = offset + 4
            let nextOffset = valueStart + paddedLength

            guard valueStart + valueLength <= data.count, nextOffset <= data.count else {
                throw STUNError.invalidMessageLength
            }

            attributes.append(STUNAttribute(type: type, value: Data(data[valueStart..<(valueStart + valueLength)])))
            offset = nextOffset
        }

        self.type = STUNMessageType(rawValue: messageType)
        self.transactionID = try STUNTransactionID(bytes: transactionBytes)
        self.attributes = attributes
        self.originalData = data
    }

    package func encoded(
        messageIntegrityKey: Data? = nil,
        includeFingerprint: Bool = false
    ) throws -> Data {
        var encodedAttributes = Data()
        for attribute in attributes {
            attribute.encode(into: &encodedAttributes)
        }

        if let messageIntegrityKey {
            let integrityLength = encodedAttributes.count + STUNAttribute.messageIntegrityByteCount
            let integrityInput = try encodedMessage(
                attributes: encodedAttributes,
                messageLengthOverride: integrityLength
            )
            let integrity = STUNCrypto.hmacSHA1(
                integrityInput,
                key: messageIntegrityKey
            )
            STUNAttribute.messageIntegrity(integrity).encode(into: &encodedAttributes)
        }

        if includeFingerprint {
            let fingerprintLength = encodedAttributes.count + STUNAttribute.fingerprintByteCount
            let fingerprintInput = try encodedMessage(
                attributes: encodedAttributes,
                messageLengthOverride: fingerprintLength
            )
            let fingerprint = STUNCrypto.fingerprint(for: fingerprintInput)
            STUNAttribute.fingerprint(fingerprint).encode(into: &encodedAttributes)
        }

        return try encodedMessage(attributes: encodedAttributes)
    }

    package func encoded(
        messageIntegrityKey: String,
        includeFingerprint: Bool = false
    ) throws -> Data {
        try encoded(messageIntegrityKey: Data(messageIntegrityKey.utf8), includeFingerprint: includeFingerprint)
    }

    package func validatesMessageIntegrity(key: Data) throws -> Bool {
        let data = try validationData()
        let location = try data.firstSTUNAttributeLocation(type: STUNAttributeType.messageIntegrity.rawValue)
        guard location.valueLength == STUNAttribute.messageIntegrityValueLength else {
            throw STUNError.invalidAttributeLength(STUNAttributeType.messageIntegrity.rawValue, location.valueLength)
        }

        var integrityInput = Data(data.prefix(location.headerOffset))
        integrityInput.setSTUNMessageLength(UInt16(location.endOffset - STUNMessage.headerByteCount))
        let expected = STUNCrypto.hmacSHA1(integrityInput, key: key)
        let actual = Data(data[location.valueRange])
        return expected == actual
    }

    package func validatesMessageIntegrity(key: String) throws -> Bool {
        try validatesMessageIntegrity(key: Data(key.utf8))
    }

    package func validatesFingerprint() throws -> Bool {
        let data = try validationData()
        let location = try data.firstSTUNAttributeLocation(type: STUNAttributeType.fingerprint.rawValue)
        guard location.valueLength == STUNAttribute.fingerprintValueLength else {
            throw STUNError.invalidAttributeLength(STUNAttributeType.fingerprint.rawValue, location.valueLength)
        }

        var fingerprintInput = Data(data.prefix(location.headerOffset))
        fingerprintInput.setSTUNMessageLength(UInt16(data.count - STUNMessage.headerByteCount))
        let expected = STUNCrypto.fingerprint(for: fingerprintInput)
        let actual = try data.networkUInt32(at: location.valueRange.lowerBound)
        return expected == actual
    }

    private func encodedMessage(
        attributes encodedAttributes: Data,
        messageLengthOverride: Int? = nil
    ) throws -> Data {
        guard encodedAttributes.count <= Int(UInt16.max) else {
            throw STUNError.invalidMessageLength
        }
        let messageLength = messageLengthOverride ?? encodedAttributes.count
        guard messageLength <= Int(UInt16.max), messageLength % 4 == 0 else {
            throw STUNError.invalidMessageLength
        }

        var data = Data()
        data.reserveCapacity(20 + encodedAttributes.count)
        data.appendNetworkUInt16(type.rawValue)
        data.appendNetworkUInt16(UInt16(messageLength))
        data.appendNetworkUInt32(Self.magicCookie)
        data.append(contentsOf: transactionID.bytes)
        data.append(encodedAttributes)
        return data
    }

    private func validationData() throws -> Data {
        if let originalData {
            return originalData
        }

        return try encoded()
    }

    package func firstAttribute(_ type: STUNAttributeType) -> STUNAttribute? {
        attributes.first { $0.type == type.rawValue }
    }
}

private extension STUNAttribute {
    static let messageIntegrityValueLength = 20
    static let fingerprintValueLength = 4
    static let headerByteCount = 4
    static let messageIntegrityByteCount = headerByteCount + messageIntegrityValueLength
    static let fingerprintByteCount = headerByteCount + fingerprintValueLength
}

private extension STUNMessage {
    static let headerByteCount = 20
}

private struct STUNAttributeLocation: Equatable {
    var headerOffset: Int
    var valueRange: Range<Int>
    var valueLength: Int

    var endOffset: Int {
        valueRange.upperBound
    }
}

private enum STUNCrypto {
    static func hmacSHA1(_ data: Data, key: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
    }

    static func fingerprint(for data: Data) -> UInt32 {
        crc32(data) ^ STUNMessage.fingerprintXORValue
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF

        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = 0 &- (crc & 1)
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }

        return crc ^ 0xFFFF_FFFF
    }
}

private extension Int {
    var stunPaddedLength: Int {
        (self + 3) & ~3
    }
}

private extension Data {
    mutating func setSTUNMessageLength(_ value: UInt16) {
        self[index(startIndex, offsetBy: 2)] = UInt8((value >> 8) & 0xFF)
        self[index(startIndex, offsetBy: 3)] = UInt8(value & 0xFF)
    }

    mutating func appendNetworkUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendNetworkUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendNetworkUInt64(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendSTUNPadding(forValueLength valueLength: Int) {
        let padding = valueLength.stunPaddedLength - valueLength
        guard padding > 0 else { return }
        append(contentsOf: repeatElement(UInt8(0), count: padding))
    }

    func networkUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw STUNError.invalidMessageLength
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return UInt16(self[first]) << 8 | UInt16(self[second])
    }

    func networkUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw STUNError.invalidMessageLength
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

    func networkUInt64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            throw STUNError.invalidMessageLength
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        let third = index(after: second)
        let fourth = index(after: third)
        let fifth = index(after: fourth)
        let sixth = index(after: fifth)
        let seventh = index(after: sixth)
        let eighth = index(after: seventh)

        return UInt64(self[first]) << 56 |
            UInt64(self[second]) << 48 |
            UInt64(self[third]) << 40 |
            UInt64(self[fourth]) << 32 |
            UInt64(self[fifth]) << 24 |
            UInt64(self[sixth]) << 16 |
            UInt64(self[seventh]) << 8 |
            UInt64(self[eighth])
    }

    func firstSTUNAttributeLocation(type targetType: UInt16) throws -> STUNAttributeLocation {
        guard count >= STUNMessage.headerByteCount else {
            throw STUNError.packetTooShort
        }

        var offset = STUNMessage.headerByteCount
        while offset < count {
            guard offset + STUNAttribute.headerByteCount <= count else {
                throw STUNError.invalidMessageLength
            }

            let type = try networkUInt16(at: offset)
            let valueLength = Int(try networkUInt16(at: offset + 2))
            let valueStart = offset + STUNAttribute.headerByteCount
            let valueEnd = valueStart + valueLength
            let nextOffset = valueStart + valueLength.stunPaddedLength

            guard valueEnd <= count, nextOffset <= count else {
                throw STUNError.invalidMessageLength
            }

            if type == targetType {
                return STUNAttributeLocation(
                    headerOffset: offset,
                    valueRange: valueStart..<valueEnd,
                    valueLength: valueLength
                )
            }

            offset = nextOffset
        }

        throw STUNError.missingAttribute(targetType)
    }
}
