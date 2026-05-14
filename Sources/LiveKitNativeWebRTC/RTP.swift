import Foundation

package enum RTPError: Error, Equatable, Sendable {
    case packetTooShort
    case unsupportedVersion(UInt8)
    case unsupportedHeaderExtension
    case invalidHeaderLength
    case invalidPadding
}

package struct RTPPacket: Equatable, Sendable {
    package var marker: Bool
    package var payloadType: UInt8
    package var sequenceNumber: UInt16
    package var timestamp: UInt32
    package var ssrc: UInt32
    package var payload: Data

    package init(
        marker: Bool,
        payloadType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    ) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    package init(decoding data: Data) throws {
        guard data.count >= 12 else {
            throw RTPError.packetTooShort
        }

        let firstByte = data[data.startIndex]
        let version = firstByte >> 6
        guard version == 2 else {
            throw RTPError.unsupportedVersion(version)
        }

        let hasPadding = (firstByte & 0x20) != 0
        let hasExtension = (firstByte & 0x10) != 0
        let csrcCount = Int(firstByte & 0x0F)

        guard !hasExtension else {
            throw RTPError.unsupportedHeaderExtension
        }

        let headerLength = 12 + (4 * csrcCount)
        guard data.count >= headerLength else {
            throw RTPError.invalidHeaderLength
        }

        let secondByte = data[data.index(after: data.startIndex)]
        marker = (secondByte & 0x80) != 0
        payloadType = secondByte & 0x7F
        sequenceNumber = try data.networkUInt16(at: 2)
        timestamp = try data.networkUInt32(at: 4)
        ssrc = try data.networkUInt32(at: 8)

        var payloadEnd = data.count
        if hasPadding {
            guard let paddingLength = data.last, paddingLength > 0, Int(paddingLength) <= data.count - headerLength else {
                throw RTPError.invalidPadding
            }

            payloadEnd -= Int(paddingLength)
        }

        payload = Data(data[data.index(data.startIndex, offsetBy: headerLength)..<data.index(data.startIndex, offsetBy: payloadEnd)])
    }

    package func encoded() -> Data {
        var data = Data()
        data.reserveCapacity(12 + payload.count)
        data.append(0x80)
        data.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        data.appendNetworkUInt16(sequenceNumber)
        data.appendNetworkUInt32(timestamp)
        data.appendNetworkUInt32(ssrc)
        data.append(payload)
        return data
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

    func networkUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw RTPError.invalidHeaderLength
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return UInt16(self[first]) << 8 | UInt16(self[second])
    }

    func networkUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw RTPError.invalidHeaderLength
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
}
