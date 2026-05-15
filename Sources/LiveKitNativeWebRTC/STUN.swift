import Foundation

package enum STUNError: Error, Equatable, Sendable {
    case packetTooShort
    case invalidMessageLength
    case invalidMagicCookie(UInt32)
    case invalidTransactionIDLength(Int)
    case invalidUTF8Attribute(UInt16)
    case invalidAddressAttribute
    case unsupportedAddressFamily(UInt8)
}

package struct STUNMessageType: RawRepresentable, Equatable, Sendable {
    package var rawValue: UInt16

    package init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    package static let bindingRequest = STUNMessageType(rawValue: 0x0001)
    package static let bindingSuccessResponse = STUNMessageType(rawValue: 0x0101)
    package static let bindingErrorResponse = STUNMessageType(rawValue: 0x0111)
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
    case xorMappedAddress = 0x0020
    case priority = 0x0024
    case useCandidate = 0x0025
    case fingerprint = 0x8028
    case iceControlled = 0x8029
    case iceControlling = 0x802A
}

package struct STUNMappedAddress: Equatable, Sendable {
    package var address: String
    package var port: UInt16

    package init(address: String, port: UInt16) {
        self.address = address
        self.port = port
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

    package static func priority(_ value: UInt32) -> STUNAttribute {
        var data = Data()
        data.appendNetworkUInt32(value)
        return STUNAttribute(type: .priority, value: data)
    }

    package static let useCandidate = STUNAttribute(type: .useCandidate)

    package static func xorMappedAddressIPv4(
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
        return STUNAttribute(type: .xorMappedAddress, value: data)
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

    package var uint64Value: UInt64? {
        guard value.count == 8 else { return nil }
        return try? value.networkUInt64(at: 0)
    }

    package var xorMappedAddressValue: STUNMappedAddress? {
        get throws {
            guard type == STUNAttributeType.xorMappedAddress.rawValue else {
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
}

package struct STUNMessage: Equatable, Sendable {
    package static let magicCookie: UInt32 = 0x2112A442

    package var type: STUNMessageType
    package var transactionID: STUNTransactionID
    package var attributes: [STUNAttribute]

    package init(
        type: STUNMessageType,
        transactionID: STUNTransactionID = .random(),
        attributes: [STUNAttribute] = []
    ) {
        self.type = type
        self.transactionID = transactionID
        self.attributes = attributes
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
    }

    package func encoded() throws -> Data {
        var encodedAttributes = Data()
        for attribute in attributes {
            attribute.encode(into: &encodedAttributes)
        }

        guard encodedAttributes.count <= Int(UInt16.max) else {
            throw STUNError.invalidMessageLength
        }

        var data = Data()
        data.reserveCapacity(20 + encodedAttributes.count)
        data.appendNetworkUInt16(type.rawValue)
        data.appendNetworkUInt16(UInt16(encodedAttributes.count))
        data.appendNetworkUInt32(Self.magicCookie)
        data.append(contentsOf: transactionID.bytes)
        data.append(encodedAttributes)
        return data
    }

    package func firstAttribute(_ type: STUNAttributeType) -> STUNAttribute? {
        attributes.first { $0.type == type.rawValue }
    }
}

private extension Int {
    var stunPaddedLength: Int {
        (self + 3) & ~3
    }
}

private extension Data {
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
}
