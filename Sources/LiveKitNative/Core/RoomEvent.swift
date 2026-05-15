import Foundation

public enum ConnectionState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case disconnecting
}

public enum ConnectionQuality: Equatable, Sendable {
    case poor
    case good
    case excellent
    case lost
    case unknown(Int)
}

public enum TrackStreamState: Equatable, Sendable {
    case active
    case paused
    case unknown(Int)
}

public enum VideoQuality: Equatable, Sendable {
    case low
    case medium
    case high
    case off
    case unknown(Int)
}

public enum SubscriptionError: Equatable, Sendable {
    case unknown
    case codecUnsupported
    case trackNotFound
    case unrecognized(Int)
}

public enum DataTrackEncryption: Equatable, Sendable {
    case none
    case gcm
    case custom
    case unknown(Int)
}

public struct RoomUpdateInfo: Equatable, Sendable {
    public let sid: String
    public let name: String
    public let metadata: String
    public let participantCount: UInt32
    public let publisherCount: UInt32
    public let isRecording: Bool

    public init(
        sid: String,
        name: String,
        metadata: String,
        participantCount: UInt32,
        publisherCount: UInt32,
        isRecording: Bool
    ) {
        self.sid = sid
        self.name = name
        self.metadata = metadata
        self.participantCount = participantCount
        self.publisherCount = publisherCount
        self.isRecording = isRecording
    }
}

public struct MediaSectionsRequirementInfo: Equatable, Sendable {
    public let audioCount: UInt32
    public let videoCount: UInt32

    public init(audioCount: UInt32, videoCount: UInt32) {
        self.audioCount = audioCount
        self.videoCount = videoCount
    }
}

public struct SpeakerInfo: Equatable, Sendable {
    public let participantSID: String
    public let level: Float
    public let isActive: Bool

    public init(participantSID: String, level: Float, isActive: Bool) {
        self.participantSID = participantSID
        self.level = level
        self.isActive = isActive
    }
}

public struct ConnectionQualityInfo: Equatable, Sendable {
    public let participantSID: String
    public let quality: ConnectionQuality
    public let score: Float

    public init(participantSID: String, quality: ConnectionQuality, score: Float) {
        self.participantSID = participantSID
        self.quality = quality
        self.score = score
    }
}

public struct TrackStreamStateInfo: Equatable, Sendable {
    public let participantSID: String
    public let trackSID: String
    public let state: TrackStreamState

    public init(participantSID: String, trackSID: String, state: TrackStreamState) {
        self.participantSID = participantSID
        self.trackSID = trackSID
        self.state = state
    }
}

public struct SubscribedQualityInfo: Equatable, Sendable {
    public let quality: VideoQuality
    public let isEnabled: Bool

    public init(quality: VideoQuality, isEnabled: Bool) {
        self.quality = quality
        self.isEnabled = isEnabled
    }
}

public struct SubscribedCodecInfo: Equatable, Sendable {
    public let codec: String
    public let qualities: [SubscribedQualityInfo]

    public init(codec: String, qualities: [SubscribedQualityInfo]) {
        self.codec = codec
        self.qualities = qualities
    }
}

public struct SubscribedQualityUpdateInfo: Equatable, Sendable {
    public let trackSID: String
    public let qualities: [SubscribedQualityInfo]
    public let codecs: [SubscribedCodecInfo]

    public init(
        trackSID: String,
        qualities: [SubscribedQualityInfo],
        codecs: [SubscribedCodecInfo]
    ) {
        self.trackSID = trackSID
        self.qualities = qualities
        self.codecs = codecs
    }
}

public struct SubscribedAudioCodecInfo: Equatable, Sendable {
    public let codec: String
    public let isEnabled: Bool

    public init(codec: String, isEnabled: Bool) {
        self.codec = codec
        self.isEnabled = isEnabled
    }
}

public struct SubscribedAudioCodecUpdateInfo: Equatable, Sendable {
    public let trackSID: String
    public let codecs: [SubscribedAudioCodecInfo]

    public init(trackSID: String, codecs: [SubscribedAudioCodecInfo]) {
        self.trackSID = trackSID
        self.codecs = codecs
    }
}

public struct SubscriptionPermissionUpdateInfo: Equatable, Sendable {
    public let participantSID: String
    public let trackSID: String
    public let isAllowed: Bool

    public init(participantSID: String, trackSID: String, isAllowed: Bool) {
        self.participantSID = participantSID
        self.trackSID = trackSID
        self.isAllowed = isAllowed
    }
}

public struct SubscriptionResponseInfo: Equatable, Sendable {
    public let trackSID: String
    public let error: SubscriptionError

    public init(trackSID: String, error: SubscriptionError) {
        self.trackSID = trackSID
        self.error = error
    }
}

public struct TrackSubscribedInfo: Equatable, Sendable {
    public let trackSID: String

    public init(trackSID: String) {
        self.trackSID = trackSID
    }
}

public struct DataTrackInfo: Equatable, Sendable {
    public let publisherHandle: UInt32
    public let sid: String
    public let name: String
    public let encryption: DataTrackEncryption

    public init(
        publisherHandle: UInt32,
        sid: String,
        name: String,
        encryption: DataTrackEncryption
    ) {
        self.publisherHandle = publisherHandle
        self.sid = sid
        self.name = name
        self.encryption = encryption
    }
}

public struct DataTrackSubscriberHandleInfo: Equatable, Sendable {
    public let subscriberHandle: UInt32
    public let publisherIdentity: String
    public let publisherSID: String
    public let trackSID: String

    public init(
        subscriberHandle: UInt32,
        publisherIdentity: String,
        publisherSID: String,
        trackSID: String
    ) {
        self.subscriberHandle = subscriberHandle
        self.publisherIdentity = publisherIdentity
        self.publisherSID = publisherSID
        self.trackSID = trackSID
    }
}

public struct DataTrackSubscriberHandlesInfo: Equatable, Sendable {
    public let handles: [DataTrackSubscriberHandleInfo]

    public init(handles: [DataTrackSubscriberHandleInfo]) {
        self.handles = handles
    }
}

public struct RoomMovedInfo: Equatable, Sendable {
    public let roomSID: String
    public let roomName: String
    public let reconnectToken: String
    public let participantSID: String
    public let participantIdentity: String
    public let remoteParticipantIdentities: [String]

    public init(
        roomSID: String,
        roomName: String,
        reconnectToken: String,
        participantSID: String,
        participantIdentity: String,
        remoteParticipantIdentities: [String]
    ) {
        self.roomSID = roomSID
        self.roomName = roomName
        self.reconnectToken = reconnectToken
        self.participantSID = participantSID
        self.participantIdentity = participantIdentity
        self.remoteParticipantIdentities = remoteParticipantIdentities
    }
}

public enum RoomEvent: Equatable, Sendable {
    case connectionStateChanged(ConnectionState)
    case participantConnected(RemoteParticipant)
    case participantDisconnected(RemoteParticipant)
    case trackPublished(RemoteTrackPublication, participant: RemoteParticipant)
    case trackUnpublished(RemoteTrackPublication, participant: RemoteParticipant)
    case speakersChanged([SpeakerInfo])
    case connectionQualityChanged([ConnectionQualityInfo])
    case streamStateChanged([TrackStreamStateInfo])
    case roomUpdated(RoomUpdateInfo)
    case subscribedQualityChanged(SubscribedQualityUpdateInfo)
    case subscribedAudioCodecChanged(SubscribedAudioCodecUpdateInfo)
    case subscriptionPermissionChanged(SubscriptionPermissionUpdateInfo)
    case subscriptionResponded(SubscriptionResponseInfo)
    case trackSubscribed(TrackSubscribedInfo)
    case mediaSectionsRequirementChanged(MediaSectionsRequirementInfo)
    case dataTrackPublished(DataTrackInfo)
    case dataTrackUnpublished(DataTrackInfo)
    case dataTrackSubscriberHandlesChanged(DataTrackSubscriberHandlesInfo)
    case roomMoved(RoomMovedInfo)
    case dataReceived(Data, participant: RemoteParticipant?, topic: String?)
    case tokenRefreshed(String)
}

public protocol RoomDelegate: AnyObject, Sendable {
    func room(_ room: Room, didEmit event: RoomEvent)
}
