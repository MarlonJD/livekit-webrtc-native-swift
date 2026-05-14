import Foundation

actor RoomActor {
    private var state: RoomState

    init(localParticipant: LocalParticipant) {
        self.state = RoomState(localParticipant: localParticipant)
    }

    func setConnectionState(_ connectionState: ConnectionState) -> RoomSnapshot {
        state.connectionState = connectionState
        return state.snapshot
    }

    func applyParticipantUpdates(_ participantUpdates: [ParticipantSnapshot]) -> (RoomSnapshot, [RoomEvent]) {
        var events: [RoomEvent] = []

        for update in participantUpdates {
            if let existing = state.remoteParticipants[update.stableKey] {
                existing.apply(update)
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
            }
        }

        return (state.snapshot, events)
    }

    func snapshot() -> RoomSnapshot {
        state.snapshot
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
