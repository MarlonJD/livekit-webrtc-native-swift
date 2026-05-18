import Foundation
import LiveKitNativeProtocol
import LiveKitNativeWebRTC

enum LiveKitDataPacketMappingError: Error, Equatable, Sendable {
    case unsupportedPacketValue
    case unsupportedSCTPPPID(SCTPDataChannelPPID)
}

struct ReceivedLiveKitDataPacket: Equatable, Sendable {
    var payload: Data
    var topic: String?
    var reliability: SCTPDataChannelReliability
    var participantSid: String?
    var participantIdentity: String?
}

enum LiveKitDataPacketMapper {
    static func makeUserPacket(
        data: Data,
        options: DataPublishOptions,
        participantSid: String? = nil,
        participantIdentity: String? = nil
    ) -> Livekit_DataPacket {
        var userPacket = Livekit_UserPacket()
        userPacket.payload = data
        userPacket.destinationIdentities = options.destinationIdentities
        if let topic = options.topic {
            userPacket.topic = topic
        }
        if let participantSid {
            userPacket.participantSid = participantSid
        }
        if let participantIdentity {
            userPacket.participantIdentity = participantIdentity
        }

        var dataPacket = Livekit_DataPacket()
        dataPacket.kind = options.reliable ? .reliable : .lossy
        dataPacket.destinationIdentities = options.destinationIdentities
        if let participantSid {
            dataPacket.participantSid = participantSid
        }
        if let participantIdentity {
            dataPacket.participantIdentity = participantIdentity
        }
        dataPacket.user = userPacket
        return dataPacket
    }

    static func receivedUserPacket(_ packet: Livekit_DataPacket) throws -> ReceivedLiveKitDataPacket {
        guard case .user(let userPacket)? = packet.value else {
            throw LiveKitDataPacketMappingError.unsupportedPacketValue
        }

        return ReceivedLiveKitDataPacket(
            payload: userPacket.payload,
            topic: userPacket.hasTopic ? userPacket.topic : nil,
            reliability: packet.kind == .reliable ? .reliable : .lossy,
            participantSid: packet.participantSid.nilIfEmpty ?? userPacket.participantSid.nilIfEmpty,
            participantIdentity: packet.participantIdentity.nilIfEmpty ?? userPacket.participantIdentity.nilIfEmpty
        )
    }

    static func decodeUserPacket(from data: Data) throws -> ReceivedLiveKitDataPacket {
        try receivedUserPacket(Livekit_DataPacket(serializedBytes: data))
    }
}

struct LocalDataPublishPlan: Equatable, Sendable {
    var packet: Livekit_DataPacket
    var encodedPacket: Data
    var reliability: SCTPDataChannelReliability
    var channelLabel: String

    init(
        data: Data,
        options: DataPublishOptions = .init(),
        participantSid: String? = nil,
        participantIdentity: String? = nil
    ) throws {
        self.reliability = options.reliable ? .reliable : .lossy
        self.channelLabel = reliability.label
        self.packet = LiveKitDataPacketMapper.makeUserPacket(
            data: data,
            options: options,
            participantSid: participantSid,
            participantIdentity: participantIdentity
        )
        self.encodedPacket = try packet.serializedData()
    }
}

actor LocalDataChannelPublisher {
    private let manager: SCTPDataChannelManager
    private let transport: any SCTPDataChannelPacketTransport
    private var openedChannelStreamIDs: Set<UInt16> = []
    private var pendingPlans: [LocalDataPublishPlan] = []
    private var liveKitChannelsInitialized = false

    init(
        manager: SCTPDataChannelManager = SCTPDataChannelManager(),
        transport: any SCTPDataChannelPacketTransport
    ) {
        self.manager = manager
        self.transport = transport
    }

    var pendingPlanCount: Int {
        pendingPlans.count
    }

    nonisolated var canReceivePackets: Bool {
        transport is any SCTPDataChannelPacketTransceiver
    }

    func streamID(for reliability: SCTPDataChannelReliability) -> UInt16 {
        ensureLiveKitChannelsInitialized()
        return manager.ensureLiveKitChannel(for: reliability).streamID
    }

    func publish(_ plan: LocalDataPublishPlan) async throws {
        ensureLiveKitChannelsInitialized()
        let channel = manager.ensureLiveKitChannel(for: plan.reliability)
        if channel.state == .open {
            try await transport.send(channel.binaryPacket(for: plan))
            return
        }

        pendingPlans.append(plan)
        do {
            try await sendOpenIfNeeded(channel)
        } catch {
            removePendingPlan(plan)
            throw error
        }
    }

    func acceptControlPacket(_ packet: SCTPDataChannelPacket) async throws {
        _ = try await acceptInboundPacket(packet)
    }

    func acceptInboundPacket(_ packet: SCTPDataChannelPacket) async throws -> ReceivedLiveKitDataPacket? {
        ensureLiveKitChannelsInitialized()
        guard packet.isControl else {
            return try receivedDataPacket(from: packet)
        }

        let message = try SCTPDataChannelControlMessage(decoding: packet.payload)
        try manager.acceptControlPacket(packet)
        if case .open = message,
           try manager.channel(for: packet.streamID).state == .open {
            try await transport.send(SCTPDataChannelPacket(
                streamID: packet.streamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            ))
        }
        try await flushPendingPlans()
        return nil
    }

    func receiveInboundPacket() async throws -> ReceivedLiveKitDataPacket? {
        guard let transceiver = transport as? any SCTPDataChannelPacketTransceiver else {
            throw LiveKitNativeError.notImplemented("SCTP data channel receive transport")
        }

        let packet = try await transceiver.receive()
        return try await acceptInboundPacket(packet)
    }

    private func ensureLiveKitChannelsInitialized() {
        guard !liveKitChannelsInitialized else {
            return
        }

        _ = manager.ensureLiveKitChannel(for: .reliable)
        _ = manager.ensureLiveKitChannel(for: .lossy)
        liveKitChannelsInitialized = true
    }

    private func sendOpenIfNeeded(_ channel: SCTPDataChannel) async throws {
        guard !openedChannelStreamIDs.contains(channel.streamID) else {
            return
        }

        try await transport.send(channel.openPacket())
        openedChannelStreamIDs.insert(channel.streamID)
    }

    private func flushPendingPlans() async throws {
        var remainingPlans: [LocalDataPublishPlan] = []
        var firstError: (any Error)?

        for plan in pendingPlans {
            guard isOpen(reliability: plan.reliability), firstError == nil else {
                remainingPlans.append(plan)
                continue
            }

            do {
                let channel = manager.ensureLiveKitChannel(for: plan.reliability)
                try await transport.send(channel.binaryPacket(for: plan))
            } catch {
                remainingPlans.append(plan)
                firstError = error
            }
        }

        pendingPlans = remainingPlans

        if let firstError {
            throw firstError
        }
    }

    private func receivedDataPacket(from packet: SCTPDataChannelPacket) throws -> ReceivedLiveKitDataPacket {
        let channel = try manager.channel(for: packet.streamID)
        guard channel.state == .open else {
            throw SCTPDataChannelError.channelNotOpen(packet.streamID)
        }

        let payload: Data
        switch packet.ppid {
        case .binary:
            payload = packet.payload
        case .binaryEmpty:
            payload = Data()
        default:
            throw LiveKitDataPacketMappingError.unsupportedSCTPPPID(packet.ppid)
        }

        return try LiveKitDataPacketMapper.decodeUserPacket(from: payload)
    }

    private func isOpen(reliability: SCTPDataChannelReliability) -> Bool {
        manager.ensureLiveKitChannel(for: reliability).state == .open
    }

    private func removePendingPlan(_ plan: LocalDataPublishPlan) {
        guard let index = pendingPlans.firstIndex(of: plan) else {
            return
        }

        pendingPlans.remove(at: index)
    }
}

private extension SCTPDataChannel {
    func binaryPacket(for plan: LocalDataPublishPlan) throws -> SCTPDataChannelPacket {
        try makeBinaryPacket(plan.encodedPacket)
    }
}

struct LocalDataTrackPublishPlan: Equatable, Sendable {
    var pubHandle: UInt32
    var name: String
    var encryption: Livekit_Encryption.TypeEnum

    init(pubHandle: UInt32, name: String, encryption: Livekit_Encryption.TypeEnum = .none) {
        self.pubHandle = pubHandle
        self.name = name
        self.encryption = encryption
    }

    var publishRequest: Livekit_PublishDataTrackRequest {
        var request = Livekit_PublishDataTrackRequest()
        request.pubHandle = pubHandle
        request.name = name
        request.encryption = encryption
        return request
    }

    var unpublishRequest: Livekit_UnpublishDataTrackRequest {
        var request = Livekit_UnpublishDataTrackRequest()
        request.pubHandle = pubHandle
        return request
    }
}

struct DataSubscriptionUpdatePlan: Equatable, Sendable {
    var trackSid: String
    var subscribe: Bool
    var targetFps: UInt32?

    init(trackSid: String, subscribe: Bool, targetFps: UInt32? = nil) {
        self.trackSid = trackSid
        self.subscribe = subscribe
        self.targetFps = targetFps
    }

    var update: Livekit_UpdateDataSubscription.Update {
        var update = Livekit_UpdateDataSubscription.Update()
        update.trackSid = trackSid
        update.subscribe = subscribe
        if let targetFps {
            var options = Livekit_DataTrackSubscriptionOptions()
            options.targetFps = targetFps
            update.options = options
        }
        return update
    }
}

extension DataTrackEncryption {
    var protocolEncryption: Livekit_Encryption.TypeEnum {
        switch self {
        case .none:
            .none
        case .gcm:
            .gcm
        case .custom:
            .custom
        case let .unknown(rawValue):
            .UNRECOGNIZED(rawValue)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
