import Foundation

public final class Room: @unchecked Sendable {
    public weak var delegate: (any RoomDelegate)?
    public let events: AsyncStream<RoomEvent>

    private let options: RoomOptions
    private let actor: RoomActor
    private let snapshots: RoomSnapshotStore
    private let eventContinuation: AsyncStream<RoomEvent>.Continuation

    public var localParticipant: LocalParticipant {
        snapshots.localParticipant
    }

    public var remoteParticipants: [RemoteParticipant] {
        snapshots.remoteParticipants
    }

    public var connectionState: ConnectionState {
        snapshots.connectionState
    }

    public init(options: RoomOptions = .init()) {
        self.options = options

        let localParticipant = LocalParticipant(identity: "local")
        self.actor = RoomActor(localParticipant: localParticipant)
        self.snapshots = RoomSnapshotStore(localParticipant: localParticipant)

        let stream = AsyncStream<RoomEvent>.makeStream(bufferingPolicy: .bufferingNewest(100))
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    deinit {
        eventContinuation.finish()
    }

    public func connect(url: URL, token: String, connectOptions: ConnectOptions = .init()) async throws {
        let autoSubscribe = connectOptions.autoSubscribe ?? options.defaultAutoSubscribe
        _ = try SignalURLBuilder(serverURL: url).build(
            token: token,
            reconnect: connectOptions.reconnect,
            autoSubscribe: autoSubscribe,
            connectOptions: connectOptions
        )

        await transition(to: .connecting)
        await transition(to: .disconnected)

        throw LiveKitNativeError.notImplemented("Signal JoinResponse handling")
    }

    public func disconnect() async {
        await transition(to: .disconnecting)
        await transition(to: .disconnected)
    }

    func applyRemoteParticipantSnapshots(_ participantSnapshots: [ParticipantSnapshot]) async {
        let result = await actor.applyParticipantUpdates(participantSnapshots)
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
    }

    private func transition(to connectionState: ConnectionState) async {
        let snapshot = await actor.setConnectionState(connectionState)
        snapshots.replace(with: snapshot)
        emit(.connectionStateChanged(connectionState))
    }

    private func emit(_ event: RoomEvent) {
        eventContinuation.yield(event)
        delegate?.room(self, didEmit: event)
    }
}
