import Foundation

public enum ConnectionState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case disconnecting
}

public enum RoomEvent: Equatable, Sendable {
    case connectionStateChanged(ConnectionState)
    case participantConnected(RemoteParticipant)
    case participantDisconnected(RemoteParticipant)
    case trackPublished(RemoteTrackPublication, participant: RemoteParticipant)
    case trackUnpublished(RemoteTrackPublication, participant: RemoteParticipant)
    case dataReceived(Data, participant: RemoteParticipant?, topic: String?)
    case tokenRefreshed(String)
}

public protocol RoomDelegate: AnyObject, Sendable {
    func room(_ room: Room, didEmit event: RoomEvent)
}
