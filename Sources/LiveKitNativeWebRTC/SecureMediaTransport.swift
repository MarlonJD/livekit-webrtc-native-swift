import Foundation

package enum SecureMediaTransportError: Error, Equatable, Sendable {
    case packetTooShort
    case srtcpIndexExhausted
}

package enum SecureMediaTransportPacket: Equatable, Sendable {
    case rtp(RTPPacket)
    case rtcp(RTCPPacket)
}

package protocol MediaDatagramTransport: Sendable {
    func send(_ datagram: Data) async throws
    func receive() async throws -> Data
}

package actor DTLSSRTPMediaTransport {
    private var packetProtectionContext: DTLSSRTPPacketProtectionContext
    private let datagramTransport: any MediaDatagramTransport
    private var outboundRTPSequenceExtenders: [UInt32: RTPSequenceNumberExtender]
    private var inboundRTPSequenceExtenders: [UInt32: RTPSequenceNumberExtender]
    private var outboundSRTCPIndex: UInt32

    package init(
        packetProtectionContext: DTLSSRTPPacketProtectionContext,
        datagramTransport: any MediaDatagramTransport
    ) {
        self.packetProtectionContext = packetProtectionContext
        self.datagramTransport = datagramTransport
        self.outboundRTPSequenceExtenders = [:]
        self.inboundRTPSequenceExtenders = [:]
        self.outboundSRTCPIndex = 0
    }

    package func sendRTP(_ packet: RTPPacket) async throws {
        var sequenceExtender = outboundRTPSequenceExtenders[packet.ssrc] ?? RTPSequenceNumberExtender()
        let extendedSequenceNumber = sequenceExtender.extend(packet.sequenceNumber)
        let rolloverCounter = UInt32(extendedSequenceNumber >> 16)
        let protected = try packetProtectionContext.protectRTP(
            packet,
            rolloverCounter: rolloverCounter
        )

        try await datagramTransport.send(protected.encoded())
        outboundRTPSequenceExtenders[packet.ssrc] = sequenceExtender
    }

    package func sendRTCP(_ packet: RTCPPacket) async throws {
        guard outboundSRTCPIndex < SRTCPIndex.maxValue else {
            throw SecureMediaTransportError.srtcpIndexExhausted
        }

        let nextIndex = outboundSRTCPIndex + 1
        let protected = try packetProtectionContext.protectRTCP(
            SRTCPPacket(
                rtcpPacket: packet,
                index: try SRTCPIndex(value: nextIndex)
            )
        )

        try await datagramTransport.send(try protected.encoded())
        outboundSRTCPIndex = nextIndex
    }

    package func receive() async throws -> SecureMediaTransportPacket {
        let datagram = try await datagramTransport.receive()
        switch try classify(datagram) {
        case .rtp:
            return try .rtp(receiveRTP(datagram))
        case .rtcp:
            return try .rtcp(packetProtectionContext.unprotectRTCP(encoded: datagram).rtcpPacket)
        }
    }

    private func receiveRTP(_ datagram: Data) throws -> RTPPacket {
        let authenticationTagLength = packetProtectionContext.protectionProfile.srtpAuthenticationTagLength
        guard datagram.count >= 12 + authenticationTagLength else {
            throw SecureMediaTransportError.packetTooShort
        }

        let rtpByteCount = datagram.count - authenticationTagLength
        let protectedRTP = try RTPPacket(decoding: Data(datagram.prefix(rtpByteCount)))
        var sequenceExtender = inboundRTPSequenceExtenders[protectedRTP.ssrc] ?? RTPSequenceNumberExtender()
        let extendedSequenceNumber = sequenceExtender.extend(protectedRTP.sequenceNumber)
        let rolloverCounter = UInt32(extendedSequenceNumber >> 16)

        let unprotected = try packetProtectionContext.unprotectRTP(
            encoded: datagram,
            rolloverCounter: rolloverCounter
        )
        inboundRTPSequenceExtenders[protectedRTP.ssrc] = sequenceExtender
        return unprotected
    }

    private func classify(_ datagram: Data) throws -> MediaDatagramKind {
        guard datagram.count >= 2 else {
            throw SecureMediaTransportError.packetTooShort
        }

        let packetType = datagram[datagram.index(after: datagram.startIndex)]
        if (192...223).contains(packetType) {
            return .rtcp
        }

        return .rtp
    }
}

private enum MediaDatagramKind {
    case rtp
    case rtcp
}
