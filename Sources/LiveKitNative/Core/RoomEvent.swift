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
    case roomMoved(RoomMovedInfo)
    case dataReceived(Data, participant: RemoteParticipant?, topic: String?)
    case tokenRefreshed(String)
}

public protocol RoomDelegate: AnyObject, Sendable {
    func room(_ room: Room, didEmit event: RoomEvent)
}
