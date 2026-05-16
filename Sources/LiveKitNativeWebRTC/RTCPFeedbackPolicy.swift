package struct RTCPFeedbackPolicy: Equatable, Sendable {
    package init() {}

    package func feedbackPackets(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        missingSequenceNumbers: [UInt16] = [],
        requestsKeyFrame: Bool = false
    ) -> [RTCPPacket] {
        var packets: [RTCPPacket] = []

        if let nack = transportLayerNACK(
            senderSSRC: senderSSRC,
            mediaSSRC: mediaSSRC,
            missingSequenceNumbers: missingSequenceNumbers
        ) {
            packets.append(nack)
        }

        if requestsKeyFrame {
            packets.append(pictureLossIndication(senderSSRC: senderSSRC, mediaSSRC: mediaSSRC))
        }

        return packets
    }

    package func transportLayerNACK(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        missingSequenceNumbers: [UInt16]
    ) -> RTCPPacket? {
        let lostPacketIDs = Self.normalizedLostPacketIDs(missingSequenceNumbers)
        guard !lostPacketIDs.isEmpty else {
            return nil
        }

        return .transportLayerNACK(
            RTCPTransportLayerNACK(
                senderSSRC: senderSSRC,
                mediaSSRC: mediaSSRC,
                lostPacketIDs: lostPacketIDs
            )
        )
    }

    package func pictureLossIndication(senderSSRC: UInt32, mediaSSRC: UInt32) -> RTCPPacket {
        .pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: senderSSRC, mediaSSRC: mediaSSRC)
        )
    }

    private static func normalizedLostPacketIDs(_ sequenceNumbers: [UInt16]) -> [UInt16] {
        Array(Set(sequenceNumbers)).sorted()
    }
}
