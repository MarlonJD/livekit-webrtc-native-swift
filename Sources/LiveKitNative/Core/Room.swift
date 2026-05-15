import Foundation
import LiveKitNativeProtocol
import LiveKitNativeWebRTC

public final class Room: @unchecked Sendable {
    public weak var delegate: (any RoomDelegate)?
    public let events: AsyncStream<RoomEvent>

    private let options: RoomOptions
    private let actor: RoomActor
    private let signalConnection: SignalConnection
    private let subscriberPeerConnection: PeerConnectionCoordinator
    private let snapshots: RoomSnapshotStore
    private let signalLoopLock = NSLock()
    private let eventContinuation: AsyncStream<RoomEvent>.Continuation
    private var signalLoopTask: Task<Void, Never>?

    public var localParticipant: LocalParticipant {
        snapshots.localParticipant
    }

    public var remoteParticipants: [RemoteParticipant] {
        snapshots.remoteParticipants
    }

    public var connectionState: ConnectionState {
        snapshots.connectionState
    }

    public convenience init(options: RoomOptions = .init()) {
        self.init(options: options, signalConnection: SignalConnection())
    }

    init(
        options: RoomOptions = .init(),
        signalConnection: SignalConnection,
        subscriberPeerConnection: PeerConnectionCoordinator = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
    ) {
        self.options = options
        self.signalConnection = signalConnection
        self.subscriberPeerConnection = subscriberPeerConnection

        let localParticipant = LocalParticipant(identity: "local")
        self.actor = RoomActor(localParticipant: localParticipant)
        self.snapshots = RoomSnapshotStore(localParticipant: localParticipant)

        let stream = AsyncStream<RoomEvent>.makeStream(bufferingPolicy: .bufferingNewest(100))
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    deinit {
        stopSignalLoop()
        Task { [signalConnection] in
            await signalConnection.close()
        }
        eventContinuation.finish()
    }

    public func connect(url: URL, token: String, connectOptions: ConnectOptions = .init()) async throws {
        let autoSubscribe = connectOptions.autoSubscribe ?? options.defaultAutoSubscribe
        let signalURL = try SignalURLBuilder(serverURL: url).build(
            token: token,
            reconnect: connectOptions.reconnect,
            autoSubscribe: autoSubscribe,
            connectOptions: connectOptions
        )

        await transition(to: .connecting)

        do {
            try await signalConnection.connect(to: signalURL)
            let response = try await signalConnection.receive(Livekit_SignalResponse.self)
            try await applyInitialSignalResponse(response)
            startSignalLoop()
        } catch {
            stopSignalLoop()
            await signalConnection.close()
            await transition(to: .disconnected)
            throw error
        }
    }

    public func disconnect() async {
        stopSignalLoop()
        await transition(to: .disconnecting)
        await signalConnection.close()
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

    private func applyInitialSignalResponse(_ response: Livekit_SignalResponse) async throws {
        guard case let .join(joinResponse)? = response.message else {
            throw LiveKitNativeError.invalidSignalFrame("Expected initial JoinResponse from LiveKit signaling.")
        }

        guard joinResponse.alternativeURL.isEmpty else {
            throw LiveKitNativeError.notImplemented("Alternative signal URL retry")
        }

        let result = await actor.applyJoin(RoomJoinSnapshot(joinResponse: joinResponse))
        snapshots.replace(with: result.0)
        emit(.connectionStateChanged(.connected))

        for event in result.1 {
            emit(event)
        }
    }

    private func startSignalLoop() {
        let task = Task { [weak self, signalConnection] in
            while !Task.isCancelled {
                do {
                    let response = try await signalConnection.receive(Livekit_SignalResponse.self)

                    guard let self else {
                        return
                    }

                    let shouldContinue = try await self.applySignalResponse(response)
                    if !shouldContinue {
                        return
                    }
                } catch {
                    if Task.isCancelled {
                        return
                    }

                    guard let self else {
                        return
                    }

                    await signalConnection.close()
                    await self.transition(to: .disconnected)
                    return
                }
            }
        }

        replaceSignalLoopTask(with: task)
    }

    private func stopSignalLoop() {
        let task = signalLoopLock.withLock {
            let task = signalLoopTask
            signalLoopTask = nil
            return task
        }
        task?.cancel()
    }

    private func replaceSignalLoopTask(with task: Task<Void, Never>) {
        let previousTask = signalLoopLock.withLock {
            let previousTask = signalLoopTask
            signalLoopTask = task
            return previousTask
        }
        previousTask?.cancel()
    }

    private func applySignalResponse(_ response: Livekit_SignalResponse) async throws -> Bool {
        guard let message = response.message else {
            return true
        }

        switch message {
        case let .update(update):
            await applyRemoteParticipantSnapshots(update.participants.map { ParticipantSnapshot(participantInfo: $0) })
            return true
        case let .refreshToken(token):
            emit(.tokenRefreshed(token))
            return true
        case let .offer(offer):
            try await answerSubscriberOffer(offer)
            return true
        case let .trickle(trickle):
            try handleTrickle(trickle)
            return true
        case let .trackUnpublished(trackUnpublished):
            await applyTrackUnpublished(trackSID: trackUnpublished.trackSid)
            return true
        case let .leave(leave):
            await handleLeaveRequest(leave)
            return false
        case .reconnect(_):
            await transition(to: .connected)
            return true
        default:
            return true
        }
    }

    private func applyTrackUnpublished(trackSID: String) async {
        let result = await actor.removeTrackPublication(sid: trackSID)
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
    }

    private func handleTrickle(_ trickle: Livekit_TrickleRequest) throws {
        guard trickle.target == .subscriber else {
            return
        }

        try subscriberPeerConnection.addRemoteICECandidate(
            candidateInitJSON: trickle.candidateInit,
            isFinal: trickle.final
        )
    }

    private func handleLeaveRequest(_ leave: Livekit_LeaveRequest) async {
        if leave.canReconnect || leave.action == .resume || leave.action == .reconnect {
            await transition(to: .reconnecting)
        } else {
            await signalConnection.close()
            await transition(to: .disconnected)
        }
    }

    private func answerSubscriberOffer(_ offer: Livekit_SessionDescription) async throws {
        var answer = Livekit_SessionDescription()
        answer.type = "answer"
        answer.sdp = try subscriberPeerConnection.makeSubscriberAnswer(for: offer.sdp)
        answer.id = offer.id

        var request = Livekit_SignalRequest()
        request.answer = answer
        try await signalConnection.send(request)
    }

    private func emit(_ event: RoomEvent) {
        eventContinuation.yield(event)
        delegate?.room(self, didEmit: event)
    }
}
