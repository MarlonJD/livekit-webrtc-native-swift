import Foundation
import LiveKitNativeProtocol

actor RoomActor {
    private var state: RoomState

    init(localParticipant: LocalParticipant) {
        self.state = RoomState(localParticipant: localParticipant)
    }

    func setConnectionState(_ connectionState: ConnectionState) -> RoomSnapshot {
        state.connectionState = connectionState
        return state.snapshot
    }

    func applyJoin(_ join: RoomJoinSnapshot) -> (RoomSnapshot, [RoomEvent]) {
        state.localParticipant = LocalParticipant(
            sid: join.localParticipant.sid,
            identity: join.localParticipant.identity,
            name: join.localParticipant.name,
            metadata: join.localParticipant.metadata,
            attributes: join.localParticipant.attributes
        )
        state.remoteParticipants.removeAll()
        state.connectionState = .connected

        var events: [RoomEvent] = []
        applyRemoteParticipantUpdates(join.remoteParticipants, events: &events)

        return (state.snapshot, events)
    }

    func applyParticipantUpdates(_ participantUpdates: [ParticipantSnapshot]) -> (RoomSnapshot, [RoomEvent]) {
        var events: [RoomEvent] = []
        applyRemoteParticipantUpdates(participantUpdates, events: &events)

        return (state.snapshot, events)
    }

    func removeTrackPublication(sid: String) -> (RoomSnapshot, [RoomEvent]) {
        var events: [RoomEvent] = []

        for participant in state.remoteParticipants.values {
            guard let publication = participant.removeTrackPublication(sid: sid) else {
                continue
            }

            events.append(.trackUnpublished(publication, participant: participant))
            break
        }

        return (state.snapshot, events)
    }

    func dataEvent(for packet: ReceivedLiveKitDataPacket) -> RoomEvent {
        .dataReceived(
            packet.payload,
            participant: remoteParticipant(sid: packet.participantSid, identity: packet.participantIdentity),
            topic: packet.topic
        )
    }

    func snapshot() -> RoomSnapshot {
        state.snapshot
    }

    private func remoteParticipant(sid: String?, identity: String?) -> RemoteParticipant? {
        state.remoteParticipants.values.first { participant in
            (!participant.sid.isEmpty && participant.sid == sid) || participant.identity == identity
        }
    }

    private func applyRemoteParticipantUpdates(_ participantUpdates: [ParticipantSnapshot], events: inout [RoomEvent]) {
        for update in participantUpdates {
            guard update.hasStableIdentity else {
                continue
            }

            if update.isDisconnected {
                guard let participant = state.remoteParticipants.removeValue(forKey: update.stableKey) else {
                    continue
                }

                let unpublishedTracks = participant.removeAllTrackPublications()
                events.append(contentsOf: unpublishedTracks.map { .trackUnpublished($0, participant: participant) })
                events.append(.participantDisconnected(participant))
                continue
            }

            if let existing = state.remoteParticipants[update.stableKey] {
                existing.apply(update)
                let addedPublications = existing.applyTrackPublications(update.trackPublications)
                events.append(contentsOf: addedPublications.map { .trackPublished($0, participant: existing) })
            } else {
                let participant = RemoteParticipant(
                    sid: update.sid,
                    identity: update.identity,
                    name: update.name,
                    metadata: update.metadata,
                    attributes: update.attributes
                )
                state.remoteParticipants[update.stableKey] = participant
                events.append(.participantConnected(participant))

                let addedPublications = participant.applyTrackPublications(update.trackPublications)
                events.append(contentsOf: addedPublications.map { .trackPublished($0, participant: participant) })
            }
        }
    }
}

struct RoomJoinSnapshot: Equatable, Sendable {
    var localParticipant: ParticipantSnapshot
    var remoteParticipants: [ParticipantSnapshot]

    init(localParticipant: ParticipantSnapshot, remoteParticipants: [ParticipantSnapshot]) {
        self.localParticipant = localParticipant
        self.remoteParticipants = remoteParticipants
    }

    init(joinResponse: Livekit_JoinResponse) {
        self.init(
            localParticipant: ParticipantSnapshot(participantInfo: joinResponse.participant, fallbackIdentity: "local"),
            remoteParticipants: joinResponse.otherParticipants.map { ParticipantSnapshot(participantInfo: $0) }
        )
    }
}

struct RoomState: Sendable {
    var connectionState: ConnectionState = .disconnected
    var localParticipant: LocalParticipant
    var remoteParticipants: [String: RemoteParticipant] = [:]

    var snapshot: RoomSnapshot {
        RoomSnapshot(
            connectionState: connectionState,
            localParticipant: localParticipant,
            remoteParticipants: Array(remoteParticipants.values)
        )
    }
}

struct RoomSnapshot: Sendable {
    var connectionState: ConnectionState
    var localParticipant: LocalParticipant
    var remoteParticipants: [RemoteParticipant]
}

final class RoomSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: RoomSnapshot

    init(localParticipant: LocalParticipant) {
        self.snapshot = RoomSnapshot(
            connectionState: .disconnected,
            localParticipant: localParticipant,
            remoteParticipants: []
        )
    }

    var localParticipant: LocalParticipant {
        lock.withLock {
            snapshot.localParticipant
        }
    }

    var remoteParticipants: [RemoteParticipant] {
        lock.withLock {
            snapshot.remoteParticipants
        }
    }

    var connectionState: ConnectionState {
        lock.withLock {
            snapshot.connectionState
        }
    }

    func replace(with snapshot: RoomSnapshot) {
        lock.withLock {
            self.snapshot = snapshot
        }
    }
}
