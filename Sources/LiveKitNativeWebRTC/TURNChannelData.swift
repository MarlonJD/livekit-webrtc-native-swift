import Foundation

package enum TURNChannelDataError: Error, Equatable, Sendable {
    case packetTooShort
    case invalidChannelNumber(UInt16)
    case invalidLength(declaredPayloadLength: Int, availableFrameBytes: Int)
}

package struct TURNChannelDataFrame: Equatable, Sendable {
    package static let minimumChannelNumber: UInt16 = 0x4000
    package static let maximumChannelNumber: UInt16 = 0x7FFF

    package var channelNumber: UInt16
    package var payload: Data

    package init(channelNumber: UInt16, payload: Data) throws {
        try Self.validateChannelNumber(channelNumber)
        try Self.validatePayloadLength(payload.count)

        self.channelNumber = channelNumber
        self.payload = payload
    }

    package init(decoding data: Data) throws {
        let result = try Self.decodeOne(from: data, offset: 0)
        guard result.consumedBytes == data.count else {
            throw TURNChannelDataError.invalidLength(
                declaredPayloadLength: result.frame.payload.count,
                availableFrameBytes: data.count - Self.headerByteCount
            )
        }

        self = result.frame
    }

    package func encoded() throws -> Data {
        try Self.validateChannelNumber(channelNumber)
        try Self.validatePayloadLength(payload.count)

        var data = Data()
        data.reserveCapacity(Self.headerByteCount + payload.count.turnChannelDataPaddedLength)
        data.appendTURNChannelDataNetworkUInt16(channelNumber)
        data.appendTURNChannelDataNetworkUInt16(UInt16(payload.count))
        data.append(payload)
        data.appendTURNChannelDataPadding(forPayloadLength: payload.count)
        return data
    }

    package static func decodeFrames(from data: Data) throws -> (frames: [TURNChannelDataFrame], remainder: Data) {
        var frames: [TURNChannelDataFrame] = []
        var offset = 0

        while offset < data.count {
            let available = data.count - offset
            guard available >= headerByteCount else {
                return (frames, Data(data[data.index(data.startIndex, offsetBy: offset)..<data.endIndex]))
            }

            let channelNumber = try data.turnChannelDataNetworkUInt16(at: offset)
            try validateChannelNumber(channelNumber)

            let payloadLength = Int(try data.turnChannelDataNetworkUInt16(at: offset + 2))
            let consumedBytes = headerByteCount + payloadLength.turnChannelDataPaddedLength
            guard available >= consumedBytes else {
                return (frames, Data(data[data.index(data.startIndex, offsetBy: offset)..<data.endIndex]))
            }

            let result = try decodeOne(from: data, offset: offset)
            frames.append(result.frame)
            offset += result.consumedBytes
        }

        return (frames, Data())
    }

    private static let headerByteCount = 4

    private init(validatedChannelNumber channelNumber: UInt16, payload: Data) {
        self.channelNumber = channelNumber
        self.payload = payload
    }

    private static func decodeOne(
        from data: Data,
        offset: Int
    ) throws -> (frame: TURNChannelDataFrame, consumedBytes: Int) {
        let available = data.count - offset
        guard available >= headerByteCount else {
            throw TURNChannelDataError.packetTooShort
        }

        let channelNumber = try data.turnChannelDataNetworkUInt16(at: offset)
        try validateChannelNumber(channelNumber)

        let payloadLength = Int(try data.turnChannelDataNetworkUInt16(at: offset + 2))
        let paddedPayloadLength = payloadLength.turnChannelDataPaddedLength
        let consumedBytes = headerByteCount + paddedPayloadLength

        guard available >= consumedBytes else {
            throw TURNChannelDataError.invalidLength(
                declaredPayloadLength: payloadLength,
                availableFrameBytes: available - headerByteCount
            )
        }

        let payloadStart = data.index(data.startIndex, offsetBy: offset + headerByteCount)
        let payloadEnd = data.index(payloadStart, offsetBy: payloadLength)
        let payload = Data(data[payloadStart..<payloadEnd])

        return (
            TURNChannelDataFrame(validatedChannelNumber: channelNumber, payload: payload),
            consumedBytes
        )
    }

    private static func validateChannelNumber(_ channelNumber: UInt16) throws {
        guard (minimumChannelNumber ... maximumChannelNumber).contains(channelNumber) else {
            throw TURNChannelDataError.invalidChannelNumber(channelNumber)
        }
    }

    private static func validatePayloadLength(_ length: Int) throws {
        guard length <= Int(UInt16.max) else {
            throw TURNChannelDataError.invalidLength(
                declaredPayloadLength: length,
                availableFrameBytes: Int(UInt16.max)
            )
        }
    }
}

private extension Int {
    var turnChannelDataPaddedLength: Int {
        (self + 3) & ~3
    }
}

private extension Data {
    mutating func appendTURNChannelDataNetworkUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendTURNChannelDataPadding(forPayloadLength payloadLength: Int) {
        let paddingLength = payloadLength.turnChannelDataPaddedLength - payloadLength
        guard paddingLength > 0 else { return }
        append(contentsOf: repeatElement(UInt8(0), count: paddingLength))
    }

    func turnChannelDataNetworkUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw TURNChannelDataError.packetTooShort
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return UInt16(self[first]) << 8 | UInt16(self[second])
    }
}
