import Foundation

package enum TURNRelayTransportError: Error, Equatable, Sendable {
    case duplicateChannelBinding(UInt16)
    case unboundChannelNumber(UInt16)
}

package struct TURNRelayChannelBinding: Equatable, Sendable {
    package var channelNumber: UInt16
    package var peerAddress: STUNMappedAddress

    package init(channelNumber: UInt16, peerAddress: STUNMappedAddress) throws {
        _ = try TURNChannelDataFrame(channelNumber: channelNumber, payload: Data())

        self.channelNumber = channelNumber
        self.peerAddress = peerAddress
    }
}

package struct TURNRelayPacket: Equatable, Sendable {
    package var channelNumber: UInt16
    package var peerAddress: STUNMappedAddress
    package var payload: Data
}

package struct TURNRelayInboundDecoder: Sendable {
    private let peerAddressesByChannel: [UInt16: STUNMappedAddress]
    private var remainder: Data

    package init(channelBindings: [TURNRelayChannelBinding]) throws {
        self.peerAddressesByChannel = try Self.makePeerAddressMap(channelBindings)
        self.remainder = Data()
    }

    package var bufferedRemainder: Data {
        remainder
    }

    package func decodeDatagram(_ data: Data) throws -> TURNRelayPacket {
        try packet(from: TURNChannelDataFrame(decoding: data))
    }

    package func decodeStream(_ data: Data) throws -> (packets: [TURNRelayPacket], remainder: Data) {
        let decoded = try TURNChannelDataFrame.decodeFrames(from: data)
        return (
            packets: try decoded.frames.map(packet(from:)),
            remainder: decoded.remainder
        )
    }

    package mutating func append(_ data: Data) throws -> [TURNRelayPacket] {
        var stream = remainder
        stream.append(data)

        let decoded = try decodeStream(stream)
        remainder = decoded.remainder
        return decoded.packets
    }

    private func packet(from frame: TURNChannelDataFrame) throws -> TURNRelayPacket {
        guard let peerAddress = peerAddressesByChannel[frame.channelNumber] else {
            throw TURNRelayTransportError.unboundChannelNumber(frame.channelNumber)
        }

        return TURNRelayPacket(
            channelNumber: frame.channelNumber,
            peerAddress: peerAddress,
            payload: frame.payload
        )
    }

    private static func makePeerAddressMap(
        _ channelBindings: [TURNRelayChannelBinding]
    ) throws -> [UInt16: STUNMappedAddress] {
        var peerAddressesByChannel: [UInt16: STUNMappedAddress] = [:]
        for binding in channelBindings {
            guard peerAddressesByChannel[binding.channelNumber] == nil else {
                throw TURNRelayTransportError.duplicateChannelBinding(binding.channelNumber)
            }

            peerAddressesByChannel[binding.channelNumber] = binding.peerAddress
        }
        return peerAddressesByChannel
    }
}

package actor TURNRelayTransport {
    private let datagramTransport: any MediaDatagramTransport
    private let peerAddressesByChannel: [UInt16: STUNMappedAddress]
    private var decoder: TURNRelayInboundDecoder
    private var pendingPackets: [TURNRelayPacket]

    package init(
        datagramTransport: any MediaDatagramTransport,
        channelBindings: [TURNRelayChannelBinding]
    ) throws {
        self.datagramTransport = datagramTransport
        self.decoder = try TURNRelayInboundDecoder(channelBindings: channelBindings)
        self.peerAddressesByChannel = Dictionary(
            uniqueKeysWithValues: channelBindings.map { ($0.channelNumber, $0.peerAddress) }
        )
        self.pendingPackets = []
    }

    package func send(_ payload: Data, to binding: TURNRelayChannelBinding) async throws {
        guard peerAddressesByChannel[binding.channelNumber] == binding.peerAddress else {
            throw TURNRelayTransportError.unboundChannelNumber(binding.channelNumber)
        }

        let frame = try TURNChannelDataFrame(
            channelNumber: binding.channelNumber,
            payload: payload
        )
        try await datagramTransport.send(frame.encoded())
    }

    package func receive() async throws -> TURNRelayPacket {
        if !pendingPackets.isEmpty {
            return pendingPackets.removeFirst()
        }

        while true {
            let datagram = try await datagramTransport.receive()
            pendingPackets.append(contentsOf: try decoder.append(datagram))

            if !pendingPackets.isEmpty {
                return pendingPackets.removeFirst()
            }
        }
    }
}
