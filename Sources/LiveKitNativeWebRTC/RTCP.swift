import Foundation

package enum RTCPError: Error, Equatable, Sendable {
    case packetTooShort
    case unsupportedVersion(UInt8)
    case invalidLength
    case unsupportedPacketType(UInt8)
    case unsupportedFeedbackFormat(UInt8, UInt8)
    case reportCountExceedsLimit(Int)
}

package struct RTCPReceptionReport: Equatable, Sendable {
    package var ssrc: UInt32
    package var fractionLost: UInt8
    package var cumulativePacketsLost: Int32
    package var highestSequenceNumber: UInt32
    package var jitter: UInt32
    package var lastSenderReport: UInt32
    package var delaySinceLastSenderReport: UInt32

    package init(
        ssrc: UInt32,
        fractionLost: UInt8,
        cumulativePacketsLost: Int32,
        highestSequenceNumber: UInt32,
        jitter: UInt32,
        lastSenderReport: UInt32,
        delaySinceLastSenderReport: UInt32
    ) {
        self.ssrc = ssrc
        self.fractionLost = fractionLost
        self.cumulativePacketsLost = cumulativePacketsLost
        self.highestSequenceNumber = highestSequenceNumber
        self.jitter = jitter
        self.lastSenderReport = lastSenderReport
        self.delaySinceLastSenderReport = delaySinceLastSenderReport
    }
}

package struct RTCPSenderReport: Equatable, Sendable {
    package var senderSSRC: UInt32
    package var ntpTimestamp: UInt64
    package var rtpTimestamp: UInt32
    package var packetCount: UInt32
    package var octetCount: UInt32
    package var reports: [RTCPReceptionReport]

    package init(
        senderSSRC: UInt32,
        ntpTimestamp: UInt64,
        rtpTimestamp: UInt32,
        packetCount: UInt32,
        octetCount: UInt32,
        reports: [RTCPReceptionReport] = []
    ) {
        self.senderSSRC = senderSSRC
        self.ntpTimestamp = ntpTimestamp
        self.rtpTimestamp = rtpTimestamp
        self.packetCount = packetCount
        self.octetCount = octetCount
        self.reports = reports
    }
}

package struct RTCPReceiverReport: Equatable, Sendable {
    package var senderSSRC: UInt32
    package var reports: [RTCPReceptionReport]

    package init(senderSSRC: UInt32, reports: [RTCPReceptionReport] = []) {
        self.senderSSRC = senderSSRC
        self.reports = reports
    }
}

package struct RTCPPictureLossIndication: Equatable, Sendable {
    package var senderSSRC: UInt32
    package var mediaSSRC: UInt32

    package init(senderSSRC: UInt32, mediaSSRC: UInt32) {
        self.senderSSRC = senderSSRC
        self.mediaSSRC = mediaSSRC
    }
}

package struct RTCPTransportLayerNACK: Equatable, Sendable {
    package var senderSSRC: UInt32
    package var mediaSSRC: UInt32
    package var lostPacketIDs: [UInt16]

    package init(senderSSRC: UInt32, mediaSSRC: UInt32, lostPacketIDs: [UInt16]) {
        self.senderSSRC = senderSSRC
        self.mediaSSRC = mediaSSRC
        self.lostPacketIDs = Array(Set(lostPacketIDs)).sorted()
    }
}

package struct RTCPReceiverEstimatedMaximumBitrate: Equatable, Sendable {
    package var senderSSRC: UInt32
    package var mediaSSRC: UInt32
    package var bitrateBps: UInt64
    package var ssrcs: [UInt32]

    package init(
        senderSSRC: UInt32,
        mediaSSRC: UInt32 = 0,
        bitrateBps: UInt64,
        ssrcs: [UInt32]
    ) {
        self.senderSSRC = senderSSRC
        self.mediaSSRC = mediaSSRC
        self.bitrateBps = bitrateBps
        self.ssrcs = Array(Set(ssrcs)).sorted()
    }
}

package struct RTCPApplicationLayerFeedback: Equatable, Sendable {
    package var senderSSRC: UInt32
    package var mediaSSRC: UInt32
    package var fci: Data

    package init(senderSSRC: UInt32, mediaSSRC: UInt32, fci: Data) {
        self.senderSSRC = senderSSRC
        self.mediaSSRC = mediaSSRC
        self.fci = fci
    }
}

package enum RTCPPacket: Equatable, Sendable {
    case senderReport(RTCPSenderReport)
    case receiverReport(RTCPReceiverReport)
    case pictureLossIndication(RTCPPictureLossIndication)
    case transportLayerNACK(RTCPTransportLayerNACK)
    case receiverEstimatedMaximumBitrate(RTCPReceiverEstimatedMaximumBitrate)
    case applicationLayerFeedback(RTCPApplicationLayerFeedback)

    package var senderSSRC: UInt32 {
        switch self {
        case let .senderReport(report):
            return report.senderSSRC
        case let .receiverReport(report):
            return report.senderSSRC
        case let .pictureLossIndication(feedback):
            return feedback.senderSSRC
        case let .transportLayerNACK(feedback):
            return feedback.senderSSRC
        case let .receiverEstimatedMaximumBitrate(feedback):
            return feedback.senderSSRC
        case let .applicationLayerFeedback(feedback):
            return feedback.senderSSRC
        }
    }

    package init(decoding data: Data) throws {
        let header = try RTCPHeader(decoding: data)
        let payload = data.dropFirst(RTCPHeader.byteCount)

        switch header.packetType {
        case RTCPPacketType.senderReport:
            self = .senderReport(try RTCPSenderReport(decodingPayload: payload, reportCount: header.count))
        case RTCPPacketType.receiverReport:
            self = .receiverReport(try RTCPReceiverReport(decodingPayload: payload, reportCount: header.count))
        case RTCPPacketType.transportLayerFeedback:
            guard header.count == RTCPFeedbackFormat.genericNACK else {
                throw RTCPError.unsupportedFeedbackFormat(header.packetType, header.count)
            }
            self = .transportLayerNACK(try RTCPTransportLayerNACK(decodingPayload: payload))
        case RTCPPacketType.payloadSpecificFeedback:
            switch header.count {
            case RTCPFeedbackFormat.pictureLossIndication:
                self = .pictureLossIndication(try RTCPPictureLossIndication(decodingPayload: payload))
            case RTCPFeedbackFormat.applicationLayerFeedback:
                if let remb = try? RTCPReceiverEstimatedMaximumBitrate(decodingPayload: payload) {
                    self = .receiverEstimatedMaximumBitrate(remb)
                } else {
                    self = .applicationLayerFeedback(try RTCPApplicationLayerFeedback(decodingPayload: payload))
                }
            default:
                throw RTCPError.unsupportedFeedbackFormat(header.packetType, header.count)
            }
        default:
            throw RTCPError.unsupportedPacketType(header.packetType)
        }
    }

    package func encoded() throws -> Data {
        switch self {
        case let .senderReport(report):
            let payload = try report.encodedPayload()
            return try RTCPHeader(count: UInt8(report.reports.count), packetType: RTCPPacketType.senderReport, payloadByteCount: payload.count)
                .encoded() + payload
        case let .receiverReport(report):
            let payload = try report.encodedPayload()
            return try RTCPHeader(count: UInt8(report.reports.count), packetType: RTCPPacketType.receiverReport, payloadByteCount: payload.count)
                .encoded() + payload
        case let .pictureLossIndication(pli):
            let payload = pli.encodedPayload()
            return try RTCPHeader(count: RTCPFeedbackFormat.pictureLossIndication, packetType: RTCPPacketType.payloadSpecificFeedback, payloadByteCount: payload.count)
                .encoded() + payload
        case let .transportLayerNACK(nack):
            let payload = nack.encodedPayload()
            return try RTCPHeader(count: RTCPFeedbackFormat.genericNACK, packetType: RTCPPacketType.transportLayerFeedback, payloadByteCount: payload.count)
                .encoded() + payload
        case let .receiverEstimatedMaximumBitrate(remb):
            let payload = try remb.encodedPayload()
            return try RTCPHeader(count: RTCPFeedbackFormat.applicationLayerFeedback, packetType: RTCPPacketType.payloadSpecificFeedback, payloadByteCount: payload.count)
                .encoded() + payload
        case let .applicationLayerFeedback(feedback):
            let payload = try feedback.encodedPayload()
            return try RTCPHeader(count: RTCPFeedbackFormat.applicationLayerFeedback, packetType: RTCPPacketType.payloadSpecificFeedback, payloadByteCount: payload.count)
                .encoded() + payload
        }
    }
}

private enum RTCPPacketType {
    static let senderReport: UInt8 = 200
    static let receiverReport: UInt8 = 201
    static let transportLayerFeedback: UInt8 = 205
    static let payloadSpecificFeedback: UInt8 = 206
}

private enum RTCPFeedbackFormat {
    static let genericNACK: UInt8 = 1
    static let pictureLossIndication: UInt8 = 1
    static let applicationLayerFeedback: UInt8 = 15
}

private struct RTCPHeader: Equatable {
    static let byteCount = 4

    var count: UInt8
    var packetType: UInt8
    var length: UInt16

    init(count: UInt8, packetType: UInt8, payloadByteCount: Int) throws {
        guard count <= 31 else {
            throw RTCPError.reportCountExceedsLimit(Int(count))
        }
        let packetByteCount = Self.byteCount + payloadByteCount
        guard packetByteCount >= Self.byteCount, packetByteCount % 4 == 0 else {
            throw RTCPError.invalidLength
        }

        self.count = count
        self.packetType = packetType
        self.length = UInt16(packetByteCount / 4 - 1)
    }

    init(decoding data: Data) throws {
        guard data.count >= Self.byteCount else {
            throw RTCPError.packetTooShort
        }

        let firstByte = data[data.startIndex]
        let version = firstByte >> 6
        guard version == 2 else {
            throw RTCPError.unsupportedVersion(version)
        }

        count = firstByte & 0x1F
        packetType = data[data.index(data.startIndex, offsetBy: 1)]
        length = try data.networkUInt16(at: 2)

        guard data.count == Int(length + 1) * 4 else {
            throw RTCPError.invalidLength
        }
    }

    func encoded() -> Data {
        var data = Data()
        data.append(0x80 | (count & 0x1F))
        data.append(packetType)
        data.appendNetworkUInt16(length)
        return data
    }
}

private extension RTCPSenderReport {
    init(decodingPayload payload: Data.SubSequence, reportCount: UInt8) throws {
        guard payload.count == 24 + Int(reportCount) * 24 else {
            throw RTCPError.invalidLength
        }
        let data = Data(payload)
        senderSSRC = try data.networkUInt32(at: 0)
        ntpTimestamp = try data.networkUInt64(at: 4)
        rtpTimestamp = try data.networkUInt32(at: 12)
        packetCount = try data.networkUInt32(at: 16)
        octetCount = try data.networkUInt32(at: 20)
        reports = try (0..<Int(reportCount)).map {
            try RTCPReceptionReport(decoding: data, offset: 24 + $0 * 24)
        }
    }

    func encodedPayload() throws -> Data {
        try validateReportCount(reports.count)
        var data = Data()
        data.appendNetworkUInt32(senderSSRC)
        data.appendNetworkUInt64(ntpTimestamp)
        data.appendNetworkUInt32(rtpTimestamp)
        data.appendNetworkUInt32(packetCount)
        data.appendNetworkUInt32(octetCount)
        for report in reports {
            report.encode(into: &data)
        }
        return data
    }
}

private extension RTCPReceiverReport {
    init(decodingPayload payload: Data.SubSequence, reportCount: UInt8) throws {
        guard payload.count == 4 + Int(reportCount) * 24 else {
            throw RTCPError.invalidLength
        }
        let data = Data(payload)
        senderSSRC = try data.networkUInt32(at: 0)
        reports = try (0..<Int(reportCount)).map {
            try RTCPReceptionReport(decoding: data, offset: 4 + $0 * 24)
        }
    }

    func encodedPayload() throws -> Data {
        try validateReportCount(reports.count)
        var data = Data()
        data.appendNetworkUInt32(senderSSRC)
        for report in reports {
            report.encode(into: &data)
        }
        return data
    }
}

private extension RTCPReceptionReport {
    init(decoding data: Data, offset: Int) throws {
        guard offset + 24 <= data.count else {
            throw RTCPError.invalidLength
        }

        ssrc = try data.networkUInt32(at: offset)
        fractionLost = data[data.index(data.startIndex, offsetBy: offset + 4)]
        let rawLost = UInt32(data[data.index(data.startIndex, offsetBy: offset + 5)]) << 16 |
            UInt32(data[data.index(data.startIndex, offsetBy: offset + 6)]) << 8 |
            UInt32(data[data.index(data.startIndex, offsetBy: offset + 7)])
        cumulativePacketsLost = (rawLost & 0x0080_0000) != 0
            ? Int32(bitPattern: rawLost | 0xFF00_0000)
            : Int32(rawLost)
        highestSequenceNumber = try data.networkUInt32(at: offset + 8)
        jitter = try data.networkUInt32(at: offset + 12)
        lastSenderReport = try data.networkUInt32(at: offset + 16)
        delaySinceLastSenderReport = try data.networkUInt32(at: offset + 20)
    }

    func encode(into data: inout Data) {
        data.appendNetworkUInt32(ssrc)
        data.append(fractionLost)
        let lost = UInt32(bitPattern: cumulativePacketsLost) & 0x00FF_FFFF
        data.append(UInt8((lost >> 16) & 0xFF))
        data.append(UInt8((lost >> 8) & 0xFF))
        data.append(UInt8(lost & 0xFF))
        data.appendNetworkUInt32(highestSequenceNumber)
        data.appendNetworkUInt32(jitter)
        data.appendNetworkUInt32(lastSenderReport)
        data.appendNetworkUInt32(delaySinceLastSenderReport)
    }
}

private extension RTCPPictureLossIndication {
    init(decodingPayload payload: Data.SubSequence) throws {
        guard payload.count == 8 else {
            throw RTCPError.invalidLength
        }
        let data = Data(payload)
        senderSSRC = try data.networkUInt32(at: 0)
        mediaSSRC = try data.networkUInt32(at: 4)
    }

    func encodedPayload() -> Data {
        var data = Data()
        data.appendNetworkUInt32(senderSSRC)
        data.appendNetworkUInt32(mediaSSRC)
        return data
    }
}

private extension RTCPTransportLayerNACK {
    init(decodingPayload payload: Data.SubSequence) throws {
        guard payload.count >= 12, payload.count % 4 == 0 else {
            throw RTCPError.invalidLength
        }
        let data = Data(payload)
        senderSSRC = try data.networkUInt32(at: 0)
        mediaSSRC = try data.networkUInt32(at: 4)
        var packetIDs: [UInt16] = []
        var offset = 8
        while offset < data.count {
            let packetID = try data.networkUInt16(at: offset)
            let bitmask = try data.networkUInt16(at: offset + 2)
            packetIDs.append(packetID)
            for bit in 0..<16 where (bitmask & (1 << UInt16(bit))) != 0 {
                packetIDs.append(packetID &+ UInt16(bit + 1))
            }
            offset += 4
        }
        lostPacketIDs = Array(Set(packetIDs)).sorted()
    }

    func encodedPayload() -> Data {
        var data = Data()
        data.appendNetworkUInt32(senderSSRC)
        data.appendNetworkUInt32(mediaSSRC)

        var pending = lostPacketIDs
        while let packetID = pending.first {
            pending.removeFirst()
            var bitmask: UInt16 = 0
            var remaining: [UInt16] = []

            for candidate in pending {
                let delta = candidate &- packetID
                if delta >= 1, delta <= 16 {
                    bitmask |= 1 << (delta - 1)
                } else {
                    remaining.append(candidate)
                }
            }

            data.appendNetworkUInt16(packetID)
            data.appendNetworkUInt16(bitmask)
            pending = remaining
        }

        return data
    }
}

private extension RTCPReceiverEstimatedMaximumBitrate {
    static let uniqueIdentifier = Data([0x52, 0x45, 0x4D, 0x42])

    init(decodingPayload payload: Data.SubSequence) throws {
        guard payload.count >= 16, payload.count % 4 == 0 else {
            throw RTCPError.invalidLength
        }
        let data = Data(payload)
        senderSSRC = try data.networkUInt32(at: 0)
        mediaSSRC = try data.networkUInt32(at: 4)
        guard Data(data[8..<12]) == Self.uniqueIdentifier else {
            throw RTCPError.invalidLength
        }

        let ssrcCount = Int(data[data.index(data.startIndex, offsetBy: 12)])
        guard data.count == 16 + ssrcCount * 4 else {
            throw RTCPError.invalidLength
        }

        let exponentAndMantissaHigh = data[data.index(data.startIndex, offsetBy: 13)]
        let exponent = UInt64(exponentAndMantissaHigh >> 2)
        let mantissa = UInt64(exponentAndMantissaHigh & 0x03) << 16 |
            UInt64(data[data.index(data.startIndex, offsetBy: 14)]) << 8 |
            UInt64(data[data.index(data.startIndex, offsetBy: 15)])
        bitrateBps = mantissa << exponent

        ssrcs = try (0..<ssrcCount).map {
            try data.networkUInt32(at: 16 + $0 * 4)
        }
    }

    func encodedPayload() throws -> Data {
        guard ssrcs.count <= 255 else {
            throw RTCPError.reportCountExceedsLimit(ssrcs.count)
        }

        var data = Data()
        data.appendNetworkUInt32(senderSSRC)
        data.appendNetworkUInt32(mediaSSRC)
        data.append(Self.uniqueIdentifier)
        data.append(UInt8(ssrcs.count))

        let encodedBitrate = Self.encodeBitrate(bitrateBps)
        data.append(UInt8((encodedBitrate.exponent << 2) | ((encodedBitrate.mantissa >> 16) & 0x03)))
        data.append(UInt8((encodedBitrate.mantissa >> 8) & 0xFF))
        data.append(UInt8(encodedBitrate.mantissa & 0xFF))

        for ssrc in ssrcs {
            data.appendNetworkUInt32(ssrc)
        }
        return data
    }

    private static func encodeBitrate(_ bitrateBps: UInt64) -> (exponent: UInt64, mantissa: UInt64) {
        var exponent: UInt64 = 0
        while exponent < 63, (bitrateBps >> exponent) > 0x3_FFFF {
            exponent += 1
        }
        return (exponent, bitrateBps >> exponent)
    }
}

private extension RTCPApplicationLayerFeedback {
    init(decodingPayload payload: Data.SubSequence) throws {
        guard payload.count >= 8, payload.count % 4 == 0 else {
            throw RTCPError.invalidLength
        }

        let data = Data(payload)
        senderSSRC = try data.networkUInt32(at: 0)
        mediaSSRC = try data.networkUInt32(at: 4)
        fci = Data(data.dropFirst(8))
    }

    func encodedPayload() throws -> Data {
        guard fci.count % 4 == 0 else {
            throw RTCPError.invalidLength
        }

        var data = Data()
        data.appendNetworkUInt32(senderSSRC)
        data.appendNetworkUInt32(mediaSSRC)
        data.append(fci)
        return data
    }
}

private func validateReportCount(_ count: Int) throws {
    guard count <= 31 else {
        throw RTCPError.reportCountExceedsLimit(count)
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

    func networkUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw RTCPError.invalidLength
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return UInt16(self[first]) << 8 | UInt16(self[second])
    }

    func networkUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw RTCPError.invalidLength
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
            throw RTCPError.invalidLength
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
