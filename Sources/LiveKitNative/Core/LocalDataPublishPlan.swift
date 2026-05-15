import Foundation
import LiveKitNativeProtocol
import LiveKitNativeWebRTC

enum LiveKitDataPacketMappingError: Error, Equatable, Sendable {
    case unsupportedPacketValue
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
    static let reliableStreamID: UInt16 = 0
    static let lossyStreamID: UInt16 = 2

    var packet: Livekit_DataPacket
    var encodedPacket: Data
    var sctpPacket: SCTPDataChannelPacket
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
        self.sctpPacket = SCTPDataChannelPacket(
            streamID: options.reliable ? Self.reliableStreamID : Self.lossyStreamID,
            ppid: encodedPacket.isEmpty ? .binaryEmpty : .binary,
            payload: encodedPacket
        )
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
