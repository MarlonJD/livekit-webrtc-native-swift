import Foundation
import LiveKitNativeWebRTC

struct PublisherMediaRTPBridge: Sendable {
    private var sendRTP: @Sendable (RTPPacket) async throws -> Void

    init(sendRTP: @escaping @Sendable (RTPPacket) async throws -> Void) {
        self.sendRTP = sendRTP
    }

    func audioSender(for plan: LocalAudioPublishPlan) -> PublisherAudioRTPSender {
        PublisherAudioRTPSender(
            packetizer: plan.packetizer,
            sendRTP: sendRTP
        )
    }

    func videoSender(for plan: LocalVideoPublishPlan) -> PublisherVideoRTPSender {
        PublisherVideoRTPSender(
            packetizer: plan.packetizer,
            sendRTP: sendRTP
        )
    }
}

final class PublisherAudioRTPSender: @unchecked Sendable {
    private let packetizer: OpusRTPPacketizer
    private let sendRTP: @Sendable (RTPPacket) async throws -> Void

    init(
        packetizer: OpusRTPPacketizer,
        sendRTP: @escaping @Sendable (RTPPacket) async throws -> Void
    ) {
        self.packetizer = packetizer
        self.sendRTP = sendRTP
    }

    @discardableResult
    func send(_ packet: OpusPacket) async throws -> RTPPacket {
        let rtpPacket = packetizer.packetize(packet)
        try await sendRTP(rtpPacket)
        return rtpPacket
    }
}

final class PublisherVideoRTPSender: @unchecked Sendable {
    private let packetizer: H264PublishRTPPacketizer
    private let sendRTP: @Sendable (RTPPacket) async throws -> Void

    init(
        packetizer: H264PublishRTPPacketizer,
        sendRTP: @escaping @Sendable (RTPPacket) async throws -> Void
    ) {
        self.packetizer = packetizer
        self.sendRTP = sendRTP
    }

    @discardableResult
    func send(_ frame: H264EncodedFrame) async throws -> [RTPPacket] {
        let rtpPackets = try packetizer.packetize(frame)
        for packet in rtpPackets {
            try await sendRTP(packet)
        }
        return rtpPackets
    }
}
