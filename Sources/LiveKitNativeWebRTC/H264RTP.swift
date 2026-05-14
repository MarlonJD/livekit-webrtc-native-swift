import Foundation

package enum H264RTPError: Error, Equatable, Sendable {
    case emptyNALUnit
    case invalidMTU(Int)
    case invalidFUAPacket
    case invalidSTAPAPacket
    case missingFragmentStart
    case sequenceNumberGap(expected: UInt16, actual: UInt16)
}

package enum H264NALUnitType: UInt8, Equatable, Sendable {
    case nonIDRSlice = 1
    case idrSlice = 5
    case sei = 6
    case sequenceParameterSet = 7
    case pictureParameterSet = 8
    case stapA = 24
    case fuA = 28
}

package struct H264RTPPacketizer: Sendable {
    package var payloadType: UInt8
    package var mtu: Int

    package init(payloadType: UInt8 = 102, mtu: Int = 1_200) {
        self.payloadType = payloadType
        self.mtu = mtu
    }

    package func packetize(
        nalUnits: [Data],
        timestamp: UInt32,
        ssrc: UInt32,
        startingSequenceNumber: UInt16
    ) throws -> [RTPPacket] {
        let maxPayloadLength = mtu - 12
        guard maxPayloadLength >= 3 else {
            throw H264RTPError.invalidMTU(mtu)
        }

        var packets: [RTPPacket] = []
        var sequenceNumber = startingSequenceNumber

        for (index, nalUnit) in nalUnits.enumerated() {
            guard !nalUnit.isEmpty else {
                throw H264RTPError.emptyNALUnit
            }

            let isLastNALUnit = index == nalUnits.count - 1
            if nalUnit.count <= maxPayloadLength {
                packets.append(
                    RTPPacket(
                        marker: isLastNALUnit,
                        payloadType: payloadType,
                        sequenceNumber: sequenceNumber,
                        timestamp: timestamp,
                        ssrc: ssrc,
                        payload: nalUnit
                    )
                )
                sequenceNumber &+= 1
                continue
            }

            let fragmentedPackets = try fragmentFUAPackets(
                nalUnit: nalUnit,
                markerOnLastPacket: isLastNALUnit,
                timestamp: timestamp,
                ssrc: ssrc,
                startingSequenceNumber: sequenceNumber,
                maxPayloadLength: maxPayloadLength
            )
            sequenceNumber &+= UInt16(fragmentedPackets.count)
            packets.append(contentsOf: fragmentedPackets)
        }

        return packets
    }

    package static func makeSTAPA(nalUnits: [Data]) throws -> Data {
        guard !nalUnits.isEmpty else {
            throw H264RTPError.emptyNALUnit
        }

        var nri: UInt8 = 0
        for nalUnit in nalUnits {
            guard let header = nalUnit.first else {
                throw H264RTPError.emptyNALUnit
            }

            nri = max(nri, header & 0x60)
        }

        var payload = Data()
        payload.append(nri | H264NALUnitType.stapA.rawValue)

        for nalUnit in nalUnits {
            guard nalUnit.count <= Int(UInt16.max) else {
                throw H264RTPError.invalidSTAPAPacket
            }

            payload.appendNetworkUInt16(UInt16(nalUnit.count))
            payload.append(nalUnit)
        }

        return payload
    }

    private func fragmentFUAPackets(
        nalUnit: Data,
        markerOnLastPacket: Bool,
        timestamp: UInt32,
        ssrc: UInt32,
        startingSequenceNumber: UInt16,
        maxPayloadLength: Int
    ) throws -> [RTPPacket] {
        let maxFragmentLength = maxPayloadLength - 2
        guard maxFragmentLength > 0 else {
            throw H264RTPError.invalidMTU(mtu)
        }

        let nalHeader = nalUnit[nalUnit.startIndex]
        let forbiddenAndNRI = nalHeader & 0xE0
        let nalType = nalHeader & 0x1F
        let fuIndicator = forbiddenAndNRI | H264NALUnitType.fuA.rawValue
        let bodyStart = nalUnit.index(after: nalUnit.startIndex)
        let body = Data(nalUnit[bodyStart..<nalUnit.endIndex])

        var packets: [RTPPacket] = []
        var sequenceNumber = startingSequenceNumber
        var offset = 0

        while offset < body.count {
            let fragmentLength = min(maxFragmentLength, body.count - offset)
            let isStart = offset == 0
            let isEnd = offset + fragmentLength == body.count
            var payload = Data()
            payload.reserveCapacity(2 + fragmentLength)
            payload.append(fuIndicator)
            payload.append((isStart ? 0x80 : 0x00) | (isEnd ? 0x40 : 0x00) | nalType)
            payload.append(contentsOf: body[body.index(body.startIndex, offsetBy: offset)..<body.index(body.startIndex, offsetBy: offset + fragmentLength)])

            packets.append(
                RTPPacket(
                    marker: markerOnLastPacket && isEnd,
                    payloadType: payloadType,
                    sequenceNumber: sequenceNumber,
                    timestamp: timestamp,
                    ssrc: ssrc,
                    payload: payload
                )
            )

            sequenceNumber &+= 1
            offset += fragmentLength
        }

        return packets
    }
}

package final class H264RTPDepacketizer: @unchecked Sendable {
    private var fragmentedNALUnit: Data?
    private var expectedSequenceNumber: UInt16?

    package init() {}

    package func append(_ packet: RTPPacket) throws -> [Data] {
        guard let firstByte = packet.payload.first else {
            throw H264RTPError.emptyNALUnit
        }

        let nalType = firstByte & 0x1F
        switch nalType {
        case 1...23:
            return [packet.payload]
        case H264NALUnitType.stapA.rawValue:
            return try unpackSTAPA(packet.payload)
        case H264NALUnitType.fuA.rawValue:
            return try appendFUA(packet)
        default:
            return []
        }
    }

    private func unpackSTAPA(_ payload: Data) throws -> [Data] {
        var nalUnits: [Data] = []
        var offset = 1

        while offset < payload.count {
            guard offset + 2 <= payload.count else {
                throw H264RTPError.invalidSTAPAPacket
            }

            let length = Int(try payload.networkUInt16(at: offset))
            offset += 2
            guard offset + length <= payload.count else {
                throw H264RTPError.invalidSTAPAPacket
            }

            nalUnits.append(Data(payload[payload.index(payload.startIndex, offsetBy: offset)..<payload.index(payload.startIndex, offsetBy: offset + length)]))
            offset += length
        }

        return nalUnits
    }

    private func appendFUA(_ packet: RTPPacket) throws -> [Data] {
        guard packet.payload.count >= 3 else {
            throw H264RTPError.invalidFUAPacket
        }

        let indicator = packet.payload[packet.payload.startIndex]
        let headerIndex = packet.payload.index(after: packet.payload.startIndex)
        let header = packet.payload[headerIndex]
        let isStart = (header & 0x80) != 0
        let isEnd = (header & 0x40) != 0
        let reconstructedHeader = (indicator & 0xE0) | (header & 0x1F)
        let fragmentStart = packet.payload.index(after: headerIndex)
        let fragment = packet.payload[fragmentStart..<packet.payload.endIndex]

        if isStart {
            var nalUnit = Data()
            nalUnit.append(reconstructedHeader)
            nalUnit.append(contentsOf: fragment)
            fragmentedNALUnit = nalUnit
            expectedSequenceNumber = packet.sequenceNumber &+ 1

            if isEnd {
                defer { resetFragmentState() }
                return [nalUnit]
            }

            return []
        }

        guard var nalUnit = fragmentedNALUnit else {
            throw H264RTPError.missingFragmentStart
        }

        if let expectedSequenceNumber, expectedSequenceNumber != packet.sequenceNumber {
            resetFragmentState()
            throw H264RTPError.sequenceNumberGap(expected: expectedSequenceNumber, actual: packet.sequenceNumber)
        }

        nalUnit.append(contentsOf: fragment)
        fragmentedNALUnit = nalUnit
        self.expectedSequenceNumber = packet.sequenceNumber &+ 1

        if isEnd {
            resetFragmentState()
            return [nalUnit]
        }

        return []
    }

    private func resetFragmentState() {
        fragmentedNALUnit = nil
        expectedSequenceNumber = nil
    }
}

private extension Data {
    mutating func appendNetworkUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func networkUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw H264RTPError.invalidSTAPAPacket
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return UInt16(self[first]) << 8 | UInt16(self[second])
    }
}
